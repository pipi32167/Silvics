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

    /// 行首 `#` 加其后空格的前缀区间，用于淡化。
    static func headingMarkerRanges(in text: String) -> [NSRange] {
        var out: [NSRange] = []
        var location = 0
        for line in WikiScanner.lineRanges(of: text) {
            let lineText = text[line]
            var hashes = 0
            for ch in lineText {
                if ch == "#" { hashes += 1 } else { break }
            }
            if hashes >= 1, hashes <= 6, lineText.dropFirst(hashes).first == " " {
                out.append(NSRange(location: location, length: hashes + 1))
            }
            location += lineText.utf16.count + 1
        }
        return out
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
