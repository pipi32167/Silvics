import Foundation
import Markdown

/// 编辑区需要的全部样式区间。单位一律是 UTF-16 的 `NSRange`。
struct EditorSpans {
    var headings: [(level: Int, range: NSRange)] = []
    var strongs: [NSRange] = []
    var emphases: [NSRange] = []
    var inlineCodes: [NSRange] = []
    var codeBlocks: [NSRange] = []
    var blockQuotes: [NSRange] = []
    var listItems: [NSRange] = []
    var markdownLinks: [NSRange] = []
    /// 标题行首的 `#` 前缀，单独淡化。
    var headingMarkers: [NSRange] = []
}

/// 语法标记（`##`、`- [ ]`、`[[`、反引号）在「光标行露源码」模式下的两组区间。
///
/// 两组都只是**颜色**差异，字符一个不动：宽度不变，行内位置不变。
/// 之所以分成两组而不是返回一个布尔，是为了让调用方一次改完属性，不用自己再分桶。
struct SyntaxMarkVisibility: Equatable {
    /// 全部标记区间，按位置升序、互不重叠。
    var all: [NSRange] = []
    /// 光标所在段落内：用可读的语法色，用户能看见、能改。
    var show: [NSRange] = []
    /// 其他段落：设为 `.clear`（看不见，但字符还在）。
    var hide: [NSRange] = []
}

/// 一个代码块里「该上色」的那段：内容行，不含围栏行。
struct CodeBlockRegion: Equatable {
    /// 内容行区间（不含首尾围栏，末尾不含换行）。
    var contentRange: NSRange
    /// 围栏上的语言标记原文（` ```swift linenums ` → `swift`）；空表示未标注或缩进代码块。
    var language: String
}

/// 把 `swift-markdown` 的 AST 区间翻译成 `NSRange`。
///
/// 关键坑（见设计文档 7.4）：`SourceLocation.column` 的单位是 **UTF-8 字节**，
/// 不是字符，也不是 UTF-16。按字符映射会让整篇中文笔记的样式全部错位。
enum MarkdownStyler {

    static func analyze(_ text: String) -> EditorSpans {
        guard !text.isEmpty else { return EditorSpans() }

        let byteToUTF16 = buildByteToUTF16Map(text)
        let lineStarts = buildUTF8LineStarts(text)
        let byteCount = text.utf8.count
        let uint16Count = text.utf16.count

        func nsRange(_ range: SourceRange?) -> NSRange? {
            guard let range else { return nil }
            let lo = range.lowerBound
            let hi = range.upperBound
            guard lo.line >= 1, lo.line <= lineStarts.count,
                  hi.line >= 1, hi.line <= lineStarts.count else { return nil }
            let loByte = lineStarts[lo.line - 1] + lo.column - 1
            let hiByte = lineStarts[hi.line - 1] + hi.column - 1
            guard loByte >= 0, hiByte >= 0,
                  loByte <= byteCount, hiByte <= byteCount,
                  loByte <= hiByte else { return nil }
            let start = Int(byteToUTF16[loByte])
            let end = Int(byteToUTF16[hiByte])
            guard start <= uint16Count, end <= uint16Count else { return nil }
            return NSRange(location: start, length: max(0, end - start))
        }

        var collector = Collector()
        collector.visit(Document(parsing: text, options: [.parseBlockDirectives]))

        var spans = EditorSpans()
        spans.headings = collector.headings.compactMap { level, source in
            nsRange(source).map { (level, $0) }
        }
        spans.strongs = collector.strongs.compactMap(nsRange)
        spans.emphases = collector.emphases.compactMap(nsRange)
        spans.inlineCodes = collector.inlineCodes.compactMap(nsRange)
        spans.codeBlocks = collector.codeBlocks.compactMap(nsRange)
        spans.blockQuotes = collector.blockQuotes.compactMap(nsRange)
        spans.listItems = collector.listItems.compactMap(nsRange)
        spans.markdownLinks = collector.links.compactMap(nsRange)
        spans.headingMarkers = headingMarkerRanges(in: text)
        return spans
    }

    /// 表格块识别（表头行 + 分隔行 + 数据行，列数一致才算）。
    ///
    /// 实现在 `TableLayout`：识别、显示宽度、kern 与渲染属性放在同一层，只此一处。
    static func tableBlocks(in text: String) -> [TableBlock] {
        TableLayout.blocks(in: text)
    }

    // MARK: - 偏移映射

    /// 每个 UTF-8 字节边界对应的 UTF-16 偏移。数组长度 = utf8.count + 1。
    static func buildByteToUTF16Map(_ text: String) -> [Int32] {
        var map = [Int32](repeating: 0, count: text.utf8.count + 1)
        var byte = 0
        var utf16 = 0
        for ch in text {
            let bytes = ch.utf8.count
            let units = ch.utf16.count
            for k in 0..<bytes {
                map[byte + k] = Int32(utf16)
            }
            byte += bytes
            utf16 += units
        }
        map[text.utf8.count] = Int32(utf16)
        return map
    }

    /// 每行起始处的 UTF-8 字节偏移，下标 0 对应第 1 行。
    static func buildUTF8LineStarts(_ text: String) -> [Int] {
        var starts: [Int] = [0]
        var offset = 0
        for byte in text.utf8 {
            offset += 1
            if byte == 0x0A { starts.append(offset) }
        }
        return starts
    }

    /// 行首 `#` 加其后空格的前缀区间。
    ///
    /// `maxLevel` 默认 3：日记只认 1–3 级标题（S03），`####` 当段落，标记也不淡化。
    /// 多空格（S04）整段算标记，避免隐藏后留下一个空档。
    static func headingMarkerRanges(in text: String, maxLevel: Int = 3) -> [NSRange] {
        scanLineMarkers(in: text, maxLevel: maxLevel).compactMap(\.heading)
    }

    // MARK: - 语法标记可见性（光标行露源码）

    /// 全部语法标记 + 按光标段落分好组的可见性。
    ///
    /// `caretParagraph` 传光标所在段落的 `NSRange`（`NSString.paragraphRange(for:)`）。
    /// 传 `nil` 表示「没有光标」，全部隐藏。
    /// 一次线性扫描 + 一次 AST 解析，不额外遍历文本。
    static func syntaxMarkerRanges(
        in text: String,
        caretParagraph: NSRange?,
        spans: EditorSpans? = nil,
        links: [WikiLink]? = nil
    ) -> SyntaxMarkVisibility {
        split(
            syntaxMarkers(in: text, spans: spans ?? analyze(text), links: links),
            caretParagraph: caretParagraph
        )
    }

    /// 只按新的光标段落重新分桶，不重解析 Markdown。
    /// 光标移动走这条路径，避免每次方向键都重建属性表。
    static func split(_ markers: [NSRange], caretParagraph: NSRange?) -> SyntaxMarkVisibility {
        var out = SyntaxMarkVisibility(all: markers)
        guard let paragraph = caretParagraph, paragraph.length > 0 else {
            out.hide = markers
            return out
        }
        let paragraphEnd = paragraph.location + paragraph.length
        for marker in markers {
            let inside = marker.length > 0
                && marker.location >= paragraph.location
                && marker.location + marker.length <= paragraphEnd
            if inside { out.show.append(marker) } else { out.hide.append(marker) }
        }
        return out
    }

    /// 收集全部语法标记区间（与光标无关）。
    ///
    /// 覆盖：标题 `#`、待办 `- [ ] `、`[[` / `]]`、行内代码反引号、围栏行反引号、
    /// 强调 `**` / `*`。代码块与行内代码里的内容不算标记（S16 / S22 / S25）。
    static func syntaxMarkers(in text: String, spans: EditorSpans, links: [WikiLink]? = nil) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []

        for markers in scanLineMarkers(in: text) {
            if let heading = markers.heading { out.append(heading) }
            if let todo = markers.todo {
                out.append(todo)
            } else if let list = markers.list {
                // 待办标记整段包含项目符号，此时不再单独出一条（S34）。
                out.append(list.visibleRange)
            }
            if let quote = markers.quote { out.append(quote) }
            if let fence = markers.fence { out.append(fence) }
        }

        for span in spans.inlineCodes {
            out += delimiterRanges(in: ns, span: span, allowed: [backtick])
        }
        for span in spans.strongs {
            out += delimiterRanges(in: ns, span: span, allowed: [asterisk, underscore])
        }
        for span in spans.emphases {
            out += delimiterRanges(in: ns, span: span, allowed: [asterisk, underscore])
        }
        for link in links ?? WikiScanner.scan(text) {
            let range = link.nsRange(in: text)
            guard range.length >= 4 else { continue }
            out.append(NSRange(location: range.location, length: 2))
            out.append(NSRange(location: range.location + range.length - 2, length: 2))
        }

        return normalize(out, length: ns.length)
    }

    /// 待办标记：`- [ ] ` / `* [x] `，从缩进后的项目符号到 `]` 后的空格（S06–S10）。
    static func todoMarkerRanges(in text: String) -> [NSRange] {
        scanLineMarkers(in: text).compactMap(\.todo)
    }

    /// 全部列表行（无序 / 有序 / 待办），按位置升序（S28–S38）。
    ///
    /// 代码块内的 `- 甲` 不算列表（S33）：围栏状态在 `scanLineMarkers` 里维护。
    /// 待办优先于无序列表（S34）：`- [ ] 甲` 只产出 `.todo`，不产出 `.unordered`。
    static func listMarkers(in text: String) -> [ListMarker] {
        scanLineMarkers(in: text).compactMap(\.list)
    }

    /// 引用行前缀（`>` 加其后空格），S20 的渲染用。
    static func quoteMarkerRanges(in text: String) -> [NSRange] {
        scanLineMarkers(in: text).compactMap(\.quote)
    }

    /// 某处所在行里 `[ ]` / `[x]` 中间那个字符的区间（勾选切换用，S39）。
    ///
    /// 只认行首待办：先找到该行，再用同一条 `todoRegex` 匹配。`]` 后无空格不算（S09）。
    static func todoCheckRange(in text: String, at location: Int) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let clamped = min(max(0, location), ns.length - 1)
        let paragraph = ns.paragraphRange(for: NSRange(location: clamped, length: 0))
        let line = ns.substring(with: paragraph)
        guard let match = todoRegex.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) else { return nil }
        let box = match.range(at: 4)
        guard box.location != NSNotFound else { return nil }
        return NSRange(location: paragraph.location + box.location, length: 1)
    }

    /// 围栏行的反引号（` ``` ` / ` ```swift ` / `~~~`），S17 / S23 / S24 / S26 / S27。
    ///
    /// 只标反引号本身，语言标记留着可见——它是判断块语言的唯一线索。
    static func codeFenceMarkerRanges(in text: String) -> [NSRange] {
        scanLineMarkers(in: text).compactMap(\.fence)
    }

    /// 每个代码块里「该上色」的内容行 + 语言标记。
    ///
    /// 区间来自 `swift-markdown` 的 `codeBlocks`（围栏块与缩进块都算），
    /// 再在块内自己找围栏行：围栏行本身不上色，只把中间的内容行交给 `CodeLexer`（H11）。
    static func codeBlockRegions(in text: String, spans: EditorSpans) -> [CodeBlockRegion] {
        guard !text.isEmpty, !spans.codeBlocks.isEmpty else { return [] }
        let ns = text as NSString
        var out: [CodeBlockRegion] = []
        for span in spans.codeBlocks {
            guard span.length > 0, span.location >= 0,
                  span.location + span.length <= ns.length else { continue }
            out += regions(in: ns, span: span)
        }
        return out
    }

    /// 围栏行整行区间（开围栏一行 + 闭围栏一行），末尾不含换行。
    ///
    /// 给渲染层「围栏行只淡化、不加色块」用（H11）。缩进代码块没有围栏，不产生区间。
    static func codeFenceLineRanges(in text: String, spans: EditorSpans) -> [NSRange] {
        guard !text.isEmpty, !spans.codeBlocks.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        for span in spans.codeBlocks {
            guard span.length > 0, span.location >= 0,
                  span.location + span.length <= ns.length else { continue }
            out += block(in: ns, span: span).fences
        }
        return out
    }

    /// 围栏行识别：行首（允许缩进）连缀 ≥3 个反引号或波浪号。
    /// 返回围栏字符、长度、以及围栏后面的语言标记。
    private static func fenceLine(_ line: String) -> (character: Character, count: Int, language: String)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let count = rest.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count).drop(while: { $0 == " " || $0 == "\t" })
        let language = String(info.prefix(while: { $0 != " " && $0 != "\t" && $0 != "`" && $0 != "~" }))
        return (first, count, language)
    }

    /// 一个代码块：内容行区间 + 首尾围栏行区间。
    private static func block(
        in ns: NSString,
        span: NSRange
    ) -> (regions: [CodeBlockRegion], fences: [NSRange]) {
        let end = span.location + span.length
        var lines: [NSRange] = []
        var index = span.location
        while index < end {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            guard lineRange.length > 0 else { break }
            lines.append(lineRange)
            index = lineRange.location + lineRange.length
        }
        guard let first = lines.first else { return ([], []) }

        /// 行文本，去掉行尾换行（`\n` / `\r\n`）。
        func lineText(_ range: NSRange) -> String {
            var r = range
            while r.length > 0 {
                let last = ns.character(at: r.location + r.length - 1)
                if last == 0x0A || last == 0x0D { r.length -= 1 } else { break }
            }
            return ns.substring(with: r)
        }

        /// 从 `start` 到 `lines[to]` 末尾（去掉尾部换行）的区间。
        func contentRange(from start: Int, to lastLine: NSRange) -> NSRange? {
            var trailing = 0
            while trailing < lastLine.length {
                let last = ns.character(at: lastLine.location + lastLine.length - 1 - trailing)
                if last == 0x0A || last == 0x0D { trailing += 1 } else { break }
            }
            let stop = lastLine.location + lastLine.length - trailing
            guard stop > start else { return nil }
            return NSRange(location: start, length: stop - start)
        }

        guard let open = fenceLine(lineText(first)) else {
            // 缩进代码块（四个空格）：没有围栏，整段按通用词法上色
            guard let range = contentRange(from: span.location, to: lines[lines.count - 1]) else {
                return ([], [])
            }
            return ([CodeBlockRegion(contentRange: range, language: "")], [])
        }

        var last = lines.count
        for k in 1..<lines.count {
            if let close = fenceLine(lineText(lines[k])),
               close.character == open.character, close.count >= open.count {
                last = k
                break
            }
        }
        guard last > 1 else { return ([], []) }
        guard let range = contentRange(from: lines[1].location, to: lines[last - 1]) else {
            return ([], [])
        }
        // 首行一定是开围栏；`last < lines.count` 时才找到闭围栏。行尾换行不算进去。
        let fenceLines = last < lines.count ? [first, lines[last]] : [first]
        let fences = fenceLines.map { line -> NSRange in
            var r = line
            while r.length > 0 {
                let ch = ns.character(at: r.location + r.length - 1)
                if ch == 0x0A || ch == 0x0D { r.length -= 1 } else { break }
            }
            return r
        }
        return ([CodeBlockRegion(contentRange: range, language: open.language)], fences)
    }

    /// 只取内容行区间。
    private static func regions(in ns: NSString, span: NSRange) -> [CodeBlockRegion] {
        block(in: ns, span: span).regions
    }

    /// 一行上可能出现的行首标记。
    private struct LineMarkers {
        var heading: NSRange?
        var todo: NSRange?
        var fence: NSRange?
        var list: ListMarker?
        var quote: NSRange?
    }

    /// 逐行一次扫描，同时维护围栏状态。
    ///
    /// 围栏状态的作用：块内的 `## x` 不变标题、`- [ ]` 不算待办（S17 / S24 / S25）。
    /// 围栏判定与 `WikiScanner` 一致：行首（允许缩进）连续 ≥3 个反引号或波浪号，
    /// 关闭要求同字符且长度不小于开启（S27 的四个反引号因此按长度 4 处理，不嵌套）。
    private static func scanLineMarkers(in text: String, maxLevel: Int = 3) -> [LineMarkers] {
        var out: [LineMarkers] = []
        var fence: (ch: Character, count: Int)? = nil

        forEachLine(in: text) { line, offset in
            var markers = LineMarkers()

            // 1. 围栏行
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            var fenceLine = false
            if let first = line.dropFirst(indent.count).first, first == "`" || first == "~" {
                let run = line.dropFirst(indent.count).prefix(while: { $0 == first }).count
                if run >= 3 {
                    if let open = fence {
                        if first == open.ch, run >= open.count {
                            fence = nil
                            fenceLine = true
                        }
                    } else {
                        fence = (first, run)
                        fenceLine = true
                    }
                    if fenceLine {
                        markers.fence = NSRange(location: offset + indent.count, length: run)
                    }
                }
            }

            // 块内（含围栏行本身）：标题与待办都不成立
            if fenceLine || fence != nil {
                out.append(markers)
                return
            }

            // 2. 标题前缀：1–3 个 `#` 后必须有空格（S02 / S03 / S21）
            var hashes = 0
            for ch in line {
                if ch == "#" { hashes += 1 } else { break }
            }
            if hashes >= 1, hashes <= maxLevel {
                var spaces = 0
                for ch in line.dropFirst(hashes) {
                    if ch == " " { spaces += 1 } else { break }
                }
                if spaces >= 1 {
                    markers.heading = NSRange(location: offset, length: hashes + spaces)
                }
            }

            // 3. 行首前缀：待办 > 无序列表 > 有序列表 > 引用
            let raw = String(line)
            let ns = raw as NSString
            let whole = NSRange(location: 0, length: ns.length)
            let indentChars = line.prefix { $0 == " " || $0 == "\t" }
            let indentWidth = indentChars.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            if let match = todoRegex.firstMatch(in: raw, range: whole) {
                let bullet = match.range(at: 2)
                let end = match.range.location + match.range.length
                if bullet.location != NSNotFound, end > bullet.location {
                    markers.todo = NSRange(location: offset + bullet.location, length: end - bullet.location)
                    let box = match.range(at: 4)
                    let mark = box.location == NSNotFound ? " " : ns.substring(with: box)
                    markers.list = ListMarker(
                        kind: .todo(checked: mark == "x" || mark == "X"),
                        indent: indentWidth,
                        markerRange: NSRange(location: offset, length: end)
                    )
                }
            } else if let match = unorderedListRegex.firstMatch(in: raw, range: whole),
                      !startsWithBrokenTodo(raw, from: match.range.location + match.range.length) {
                let end = match.range.location + match.range.length
                markers.list = ListMarker(
                    kind: .unordered,
                    indent: indentWidth,
                    markerRange: NSRange(location: offset, length: end)
                )
            } else if let match = orderedListRegex.firstMatch(in: raw, range: whole),
                      !startsWithBrokenTodo(raw, from: match.range.location + match.range.length) {
                let end = match.range.location + match.range.length
                let digits = match.range(at: 2)
                let number = digits.location == NSNotFound
                    ? 1
                    : (Int(ns.substring(with: digits)) ?? 1)
                markers.list = ListMarker(
                    kind: .ordered(number),
                    indent: indentWidth,
                    markerRange: NSRange(location: offset, length: end)
                )
            }

            // 4. 引用前缀：`>` 后允许一个空格
            let afterIndent = raw.dropFirst(indentChars.count)
            if afterIndent.first == ">" {
                let quotes = afterIndent.prefix { $0 == ">" }.count
                var length = indentChars.count + quotes
                let rest = Array(afterIndent.dropFirst(quotes))
                if rest.first == " " { length += 1 }
                markers.quote = NSRange(location: offset, length: length)
            }

            out.append(markers)
        }
        return out
    }

    // MARK: - 标记的小工具

    private static let backtick = UInt16(UInt8(ascii: "`"))
    private static let asterisk = UInt16(UInt8(ascii: "*"))
    private static let underscore = UInt16(UInt8(ascii: "_"))

    /// 待办：`^\s*[-*+]\s+\[[ xX]\](\s+|$)`。`]` 后必须跟空格或行尾（S09）。
    private static let todoRegex = try! NSRegularExpression(
        pattern: "^([ \\t]*)([-*+])([ \\t]+)\\[([ xX])\\]([ \\t]+|$)"
    )

    /// 无序列表：`-` / `*` / `+` 后必须有空格（S28 / S29）。
    private static let unorderedListRegex = try! NSRegularExpression(
        pattern: "^([ \\t]*)([-*+])([ \\t]+)"
    )

    /// 有序列表：任意位数数字 + `.` 或 `)` + 空格（S30 / S31 / S32）。
    private static let orderedListRegex = try! NSRegularExpression(
        pattern: "^([ \\t]*)([0-9]{1,9})([.)])([ \\t]+)"
    )

    /// 无序 / 有序列表后面紧跟一个写坏的勾选框（`- [ ]a`、`- []`）时，不降级成列表。
    ///
    /// 理由：S09 规定 `]` 后无空格不算待办。若此时还按列表渲染，
    /// 用户会看到一个项目符号加上一串原文 `[ ]a`，比直接露原文更难读。
    private static func startsWithBrokenTodo(_ line: String, from index: Int) -> Bool {
        guard index < line.count else { return false }
        let rest = String(line.dropFirst(index))
        guard rest.hasPrefix("[") else { return false }
        let ns = rest as NSString
        return brokenTodoRegex.firstMatch(
            in: rest,
            range: NSRange(location: 0, length: ns.length)
        ) != nil
    }

    /// `[` + 可选空白或 x/X + `]`：写坏的勾选框形状。
    private static let brokenTodoRegex = try! NSRegularExpression(pattern: "^\\[[ xX]?\\]")

    /// 区间首尾的定界符串（`**`、`` ` ``、`*`）。
    private static func delimiterRanges(
        in ns: NSString,
        span: NSRange,
        allowed: [UInt16]
    ) -> [NSRange] {
        guard span.length > 0, span.location >= 0, span.location + span.length <= ns.length else { return [] }
        let start = span.location
        let end = span.location + span.length
        func isDelimiter(_ i: Int) -> Bool {
            i >= 0 && i < ns.length && allowed.contains(ns.character(at: i))
        }
        var out: [NSRange] = []
        if isDelimiter(start) {
            var i = start
            while i < end, isDelimiter(i) { i += 1 }
            out.append(NSRange(location: start, length: i - start))
        }
        if isDelimiter(end - 1) {
            var i = end - 1
            while i >= start, isDelimiter(i) { i -= 1 }
            out.append(NSRange(location: i + 1, length: end - 1 - i))
        }
        return out
    }

    /// 裁到文本范围内、排序、去掉重叠与空区间。
    private static func normalize(_ ranges: [NSRange], length: Int) -> [NSRange] {
        var cleaned: [NSRange] = []
        for range in ranges where range.length > 0 {
            guard range.location >= 0, range.location < length else { continue }
            let clamped = min(range.length, length - range.location)
            guard clamped > 0 else { continue }
            cleaned.append(NSRange(location: range.location, length: clamped))
        }
        cleaned.sort { $0.location != $1.location ? $0.location < $1.location : $0.length < $1.length }
        var out: [NSRange] = []
        var cursor = 0
        for range in cleaned where range.location >= cursor {
            out.append(range)
            cursor = range.location + range.length
        }
        return out
    }

    /// 逐行回调：`line` 不含换行符，`offset` 是该行首的 UTF-16 偏移。
    private static func forEachLine(in text: String, _ body: (Substring, Int) -> Void) {
        var offset = 0
        for line in WikiScanner.lineRanges(of: text) {
            body(text[line], offset)
            offset += text[line].utf16.count + 1
        }
    }

    // MARK: - 收集器

    private struct Collector: MarkupWalker {
        var headings: [(Int, SourceRange?)] = []
        var strongs: [SourceRange?] = []
        var emphases: [SourceRange?] = []
        var inlineCodes: [SourceRange?] = []
        var codeBlocks: [SourceRange?] = []
        var blockQuotes: [SourceRange?] = []
        var listItems: [SourceRange?] = []
        var links: [SourceRange?] = []

        mutating func visitHeading(_ heading: Heading) {
            headings.append((heading.level, heading.range))
            descendInto(heading)
        }
        mutating func visitStrong(_ strong: Strong) {
            strongs.append(strong.range)
            descendInto(strong)
        }
        mutating func visitEmphasis(_ emphasis: Emphasis) {
            emphases.append(emphasis.range)
            descendInto(emphasis)
        }
        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            inlineCodes.append(inlineCode.range)
        }
        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            codeBlocks.append(codeBlock.range)
        }
        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            blockQuotes.append(blockQuote.range)
            descendInto(blockQuote)
        }
        mutating func visitListItem(_ listItem: ListItem) {
            listItems.append(listItem.range)
            descendInto(listItem)
        }
        mutating func visitLink(_ link: Link) {
            links.append(link.range)
            descendInto(link)
        }
    }
}
