import Foundation

/// 代码高亮的一小段文本（区间 + 类别）。**只描述区间，一个字符都不改。**
///
/// 区间是 UTF-16 的 `NSRange`（与 `NSTextStorage` 同单位，见 AGENTS.md 硬约束）。
struct CodeToken: Equatable {
    var range: NSRange
    var kind: CodeTokenKind
}

/// token 有哪些类别。`plain` 表示「不需要上色」，调用方应当跳过。
enum CodeTokenKind: String, Equatable, CaseIterable {
    case keyword
    case string
    case comment
    case number
    case function
    case plain
}

/// 词法器认识的语言。`generic` 是未知标记的兜底。
enum CodeLanguage: String, Equatable, CaseIterable {
    case swift
    case js
    case python
    case json
    case bash
    case latex
    case generic

    /// 围栏标记归一：大小写、`ts`→js、`sh`→bash、`math`→latex、未知→generic。
    ///
    /// 只取标记的第一个「词」：` ```swift linenums ` 归到 swift，与原型 `normalizeLang` 一致。
    static func normalize(_ raw: String) -> CodeLanguage {
        var name = ""
        for ch in raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            // 原型用的是 `split(/[^a-z0-9+#-]/)[0]`，只认 ASCII 的字母数字与 `+#-`
            guard ch.isASCII, ch.isLetter || ch.isNumber || ch == "+" || ch == "#" || ch == "-" else { break }
            name.append(ch)
        }
        switch name {
        case "js", "javascript", "ts", "typescript", "jsx", "tsx": return .js
        case "py", "python3": return .python
        case "sh", "shell", "zsh", "console": return .bash
        case "math", "tex", "katex": return .latex
        default: return CodeLanguage(rawValue: name) ?? .generic
        }
    }
}

/// 表驱动词法器。纯 Swift，不依赖 AppKit，可单测。
///
/// 语义与 `prototype/journal/app.js` 的 `lexCode` 对齐（H01–H14 在原型里已经跑过）。
/// 唯一的偏离：单引号/双引号字符串**不跨行**。原型的引号扫描会一直吃到块里下一个引号，
/// bash 里一个撇号就能把后文整段变成字符串；这里到行尾没收口就按「未闭合」就地结束。
///
/// 多行结构（块注释、Python 三引号、JS 模板字符串）在整块代码上一次扫完，所以跨行正确。
/// 未闭合的结构吃到块尾，且状态不外泄：每次 `lex` 都是新的扫描，没有跨块游标（H12）。
enum CodeLexer {

    // MARK: - 入口

    /// 按围栏上的语言标记（原始文本）切 token。
    static func lex(_ code: String, language raw: String) -> [CodeToken] {
        lex(code, language: CodeLanguage.normalize(raw))
    }

    /// 按已归一的语言切 token。返回的 token 按位置升序、互不重叠、首尾相接覆盖全文。
    static func lex(_ code: String, language: CodeLanguage) -> [CodeToken] {
        guard !code.isEmpty else { return [] }

        let scalars = Array(code.unicodeScalars)
        let count = scalars.count
        // 每个下标对应的 UTF-16 偏移。区间全部落在这个坐标系里（中文注释也不会错位）。
        var offsets = [Int](repeating: 0, count: count + 1)
        for k in 0..<count {
            offsets[k + 1] = offsets[k] + (scalars[k].value > 0xFFFF ? 2 : 1)
        }

        let rules = rules(for: language)
        let keywords = keywords(for: language)
        var tokens: [CodeToken] = []

        /// 追加 `[start, end)`，与上一个同类 token 相邻则合并（减少属性 run）。
        func append(_ start: Int, _ end: Int, _ kind: CodeTokenKind) {
            guard end > start else { return }
            let range = NSRange(location: offsets[start], length: offsets[end] - offsets[start])
            if let last = tokens.last, last.kind == kind,
               last.range.location + last.range.length == range.location {
                tokens[tokens.count - 1].range.length += range.length
            } else {
                tokens.append(CodeToken(range: range, kind: kind))
            }
        }

        func starts(_ at: Int, _ marker: [Unicode.Scalar]) -> Bool {
            guard at + marker.count <= count else { return false }
            for k in 0..<marker.count where scalars[at + k] != marker[k] { return false }
            return true
        }

        func find(_ marker: [Unicode.Scalar], from: Int) -> Int? {
            guard !marker.isEmpty, from <= count - marker.count else { return nil }
            var at = from
            while at <= count - marker.count {
                if starts(at, marker) { return at }
                at += 1
            }
            return nil
        }

        let newline: Unicode.Scalar = "\n"
        let backslash: Unicode.Scalar = "\\"

        func isNewline(_ s: Unicode.Scalar) -> Bool { s == newline }
        func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
        func isIdentStart(_ s: Unicode.Scalar) -> Bool {
            s == "_" || s == "$" || (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
        }
        func isIdentBody(_ s: Unicode.Scalar) -> Bool { isIdentStart(s) || isDigit(s) }
        func isBlank(_ s: Unicode.Scalar) -> Bool {
            s == " " || s == "\t" || s == "\r" || s == "\n"
        }

        var i = 0
        while i < count {
            let current = scalars[i]

            // 1. 反斜杠命令（latex）：`\frac`、`\alpha` 当关键字
            if rules.backslashCommands, current == backslash {
                var j = i + 1
                while j < count, isAsciiLetter(scalars[j]) { j += 1 }
                if j > i + 1 {
                    append(i, j, .keyword)
                    i = j
                    continue
                }
            }

            // 2. 块注释（swift / js / generic）
            if let block = rules.blockComment, starts(i, block.open) {
                let open = block.open
                let close = block.close
                let stop = find(close, from: i + open.count).map { $0 + close.count } ?? count
                append(i, stop, .comment)
                i = stop
                continue
            }

            // 3. 行注释（`//`、`#`、`%`）。bash 的 `#` 只有出现在词首才算（`echo $#` 不算）
            if let lineMark = rules.lineComments.first(where: { starts(i, $0) }) {
                let atWordStart = i == 0 || isBlank(scalars[i - 1])
                if !rules.lineCommentNeedsWordStart || atWordStart {
                    var j = i
                    while j < count, !isNewline(scalars[j]) { j += 1 }
                    append(i, j, .comment)
                    i = j
                    continue
                }
            }

            // 4. 跨行字符串（Python 三引号、JS 模板字符串）
            if let marker = rules.multiline.first(where: { starts(i, $0) }) {
                let stop = find(marker, from: i + marker.count).map { $0 + marker.count } ?? count
                append(i, stop, .string)
                i = stop
                continue
            }

            // 5. 单行字符串。反斜杠转义要跳过；到行尾还没收口就到此为止
            if let quote = rules.quotes.first(where: { starts(i, $0) }) {
                var j = i + quote.count
                while j < count {
                    if scalars[j] == backslash {
                        j += 2
                        continue
                    }
                    if starts(j, quote) {
                        j += quote.count
                        break
                    }
                    if isNewline(scalars[j]) { break }
                    j += 1
                }
                let stop = min(j, count)
                append(i, stop, .string)
                i = stop
                continue
            }

            // 6. 数字：`0x1F`、`3`、`2.5`、`1e-3`
            if isDigit(current) {
                var j = i + 1
                if current == "0", j < count, scalars[j] == "x" || scalars[j] == "X" {
                    var k = j + 1
                    while k < count, isHexDigit(scalars[k]) { k += 1 }
                    if k > j + 1 { j = k }
                } else {
                    while j < count, isDigit(scalars[j]) { j += 1 }
                    if j < count, scalars[j] == ".", j + 1 < count, isDigit(scalars[j + 1]) {
                        j += 1
                        while j < count, isDigit(scalars[j]) { j += 1 }
                    }
                    if j < count, scalars[j] == "e" || scalars[j] == "E" {
                        var k = j + 1
                        if k < count, scalars[k] == "+" || scalars[k] == "-" { k += 1 }
                        let digitsStart = k
                        while k < count, isDigit(scalars[k]) { k += 1 }
                        if k > digitsStart { j = k }
                    }
                }
                append(i, j, .number)
                i = j
                continue
            }

            // 7. 标识符：关键字 / 后跟 `(` 的函数名 / 普通字
            if isIdentStart(current) {
                var j = i + 1
                while j < count, isIdentBody(scalars[j]) { j += 1 }
                let word = String(String.UnicodeScalarView(scalars[i..<j]))
                if keywords.contains(word) {
                    append(i, j, .keyword)
                } else if j < count, scalars[j] == "(" {
                    append(i, j, .function)
                } else {
                    append(i, j, .plain)
                }
                i = j
                continue
            }

            // 8. 其余字符原样归到 plain（连续合并）
            append(i, i + 1, .plain)
            i += 1
        }

        return tokens
    }

    // MARK: - 规则表

    /// 一门语言的词法规则。字符串标记在表里是 `String`，内部按 Unicode 标量比较。
    private struct LexRules {
        var lineComments: [[Unicode.Scalar]] = []
        var blockComment: (open: [Unicode.Scalar], close: [Unicode.Scalar])?
        var quotes: [[Unicode.Scalar]] = []
        var multiline: [[Unicode.Scalar]] = []
        /// bash：`#` 只有出现在词首才是注释（否则 `echo $#` 会被当注释）。
        var lineCommentNeedsWordStart = false
        /// latex：`\frac` 这类命令当关键字。
        var backslashCommands = false
    }

    private static func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    private static func rules(for language: CodeLanguage) -> LexRules {
        switch language {
        case .swift:
            var r = LexRules()
            r.lineComments = [scalars("//")]
            r.blockComment = (scalars("/*"), scalars("*/"))
            r.quotes = [scalars("\"")]
            return r
        case .js:
            var r = LexRules()
            r.lineComments = [scalars("//")]
            r.blockComment = (scalars("/*"), scalars("*/"))
            r.quotes = [scalars("\""), scalars("'")]
            r.multiline = [scalars("`")]
            return r
        case .python:
            var r = LexRules()
            r.lineComments = [scalars("#")]
            r.quotes = [scalars("\""), scalars("'")]
            r.multiline = [scalars("\"\"\""), scalars("'''")]
            return r
        case .json:
            // JSON 没有注释，也没有 `'` 字符串（H07）
            var r = LexRules()
            r.quotes = [scalars("\"")]
            return r
        case .bash:
            var r = LexRules()
            r.lineComments = [scalars("#")]
            r.lineCommentNeedsWordStart = true
            r.quotes = [scalars("\""), scalars("'")]
            return r
        case .latex:
            var r = LexRules()
            r.lineComments = [scalars("%")]
            r.backslashCommands = true
            return r
        case .generic:
            var r = LexRules()
            r.lineComments = [scalars("//"), scalars("#")]
            r.blockComment = (scalars("/*"), scalars("*/"))
            r.quotes = [scalars("\""), scalars("'")]
            return r
        }
    }

    /// 关键字表。`static let` 只建一次：300 行的块不能每次都拼 Set。
    private static let keywordTable: [CodeLanguage: Set<String>] = [
        .swift: words("""
        let var func class struct enum protocol extension import return if else guard switch case for while \
        repeat in where try catch throw throws defer init deinit self super nil true false async await actor \
        some any typealias public private internal fileprivate open static final override mutating lazy weak unowned
        """),
        .js: words("""
        const let var function return if else for while do switch case break continue class extends new this super \
        import export default async await try catch throw typeof instanceof in of null undefined true false yield \
        static get set delete void
        """),
        .python: words("""
        def class return if elif else for while break continue import from as try except finally raise with lambda \
        pass yield global nonlocal assert del in is not and or None True False async await match case self
        """),
        .json: words("true false null"),
        .bash: words("""
        if then else elif fi for while do done case esac function in export local echo cd ls cp mv rm mkdir rmdir \
        cat grep sed awk read printf exit return set unset source trap shift
        """),
        // TeX 没有关键字，命令靠反斜杠识别
        .latex: [],
        .generic: [],
    ]

    private static func keywords(for language: CodeLanguage) -> Set<String> {
        keywordTable[language] ?? []
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    // MARK: - 字符判断

    private static func isAsciiLetter(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
    }

    private static func isHexDigit(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 48 && s.value <= 57) || (s.value >= 65 && s.value <= 70) || (s.value >= 97 && s.value <= 102)
    }
}
