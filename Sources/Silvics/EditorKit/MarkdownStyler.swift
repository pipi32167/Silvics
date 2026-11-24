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
            if let todo = markers.todo { out.append(todo) }
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

    /// 围栏行的反引号（` ``` ` / ` ```swift ` / `~~~`），S17 / S23 / S24 / S26 / S27。
    ///
    /// 只标反引号本身，语言标记留着可见——它是判断块语言的唯一线索。
    static func codeFenceMarkerRanges(in text: String) -> [NSRange] {
        scanLineMarkers(in: text).compactMap(\.fence)
    }

    /// 一行上可能出现的三种行首标记。
    private struct LineMarkers {
        var heading: NSRange?
        var todo: NSRange?
        var fence: NSRange?
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

            // 3. 待办前缀：`]` 后必须跟空格或行尾（S09）
            let raw = String(line)
            if let match = todoRegex.firstMatch(
                in: raw,
                range: NSRange(location: 0, length: (raw as NSString).length)
            ) {
                let bullet = match.range(at: 2)
                let end = match.range.location + match.range.length
                if bullet.location != NSNotFound, end > bullet.location {
                    markers.todo = NSRange(location: offset + bullet.location, length: end - bullet.location)
                }
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
