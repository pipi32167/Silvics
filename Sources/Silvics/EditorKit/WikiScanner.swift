import Foundation

/// 正文中的一条 `[[ ]]` 引用。
struct WikiLink: Equatable, Hashable {
    /// 整段 `[[...]]` 在原文中的区间。
    var range: Range<String.Index>
    /// 目标标题。
    var target: String
    /// `[[目标|显示名]]` 中的显示名。
    var display: String?
    /// `[[目标#小标题]]` 中的小标题。
    var anchor: String?

    /// 整段 `[[...]]` 的 UTF-16 区间，可直接喂给 `NSTextStorage`。
    func nsRange(in text: String) -> NSRange {
        NSRange(range, in: text)
    }
}

/// `[[ ]]` 扫描器。
///
/// 不依赖通用 Markdown 解析器。理由见设计文档 7.4：
/// 编辑器需要的是字符区间，不是 AST；cmark 也不认识这个语法。
///
/// 跳过：围栏代码块、行内代码、URL。
enum WikiScanner {

    static func scan(_ text: String) -> [WikiLink] {
        guard text.contains("[[") else { return [] }

        var links: [WikiLink] = []
        let lines = lineRanges(of: text)

        var fence: String? = nil   // 当前的围栏标记，如 "```" 或 "~~~~"

        for lineRange in lines {
            let line = text[lineRange]
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })

            // 1. 围栏代码块
            if let marker = fenceMarker(trimmed) {
                if let current = fence {
                    if marker.hasPrefix(String(current.prefix(1))) && marker.count >= current.count {
                        fence = nil
                    }
                } else {
                    fence = marker
                }
                continue
            }
            if fence != nil { continue }

            // 2. 行内遮罩：代码与 URL
            let masked = maskedRanges(in: line, offsetInText: lineRange.lowerBound, of: text)

            // 3. 在未遮罩区间里找 [[ ]]
            var cursor = line.startIndex
            while cursor < line.endIndex {
                guard let open = text.range(of: "[[", range: cursor..<line.endIndex) else { break }
                if isMasked(open.lowerBound, masked, text) {
                    cursor = open.upperBound
                    continue
                }
                guard let close = text.range(of: "]]", range: open.upperBound..<line.endIndex) else {
                    cursor = open.upperBound
                    continue
                }
                let inner = text[open.upperBound..<close.lowerBound]
                // 跨行的引用不支持
                if inner.contains("\n") {
                    cursor = open.upperBound
                    continue
                }
                if let link = parse(inner: String(inner), fullRange: open.lowerBound..<close.upperBound) {
                    links.append(link)
                }
                cursor = close.upperBound
            }
        }

        return links
    }

    // MARK: - 解析内部

    private static func parse(inner raw: String, fullRange: Range<String.Index>) -> WikiLink? {
        var body = raw.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }

        var display: String? = nil
        if let pipe = body.firstIndex(of: "|") {
            display = String(body[body.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<pipe]).trimmingCharacters(in: .whitespaces)
        }

        var anchor: String? = nil
        if let hash = body.firstIndex(of: "#") {
            anchor = String(body[body.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<hash]).trimmingCharacters(in: .whitespaces)
        }

        guard !body.isEmpty else { return nil }
        if display?.isEmpty == true { display = nil }
        if anchor?.isEmpty == true { anchor = nil }

        return WikiLink(range: fullRange, target: body, display: display, anchor: anchor)
    }

    // MARK: - 行与遮罩

    /// 按行切分，保留每行的区间（不含换行符）。
    static func lineRanges(of text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\n" {
                ranges.append(start..<i)
                start = text.index(after: i)
            }
            i = text.index(after: i)
        }
        ranges.append(start..<text.endIndex)
        return ranges
    }

    /// 行首若是围栏标记，返回该标记（如 "```" / "````" / "~~~"）。
    private static func fenceMarker(_ line: Substring) -> String? {
        for ch in ["`", "~"] {
            let run = line.prefix(while: { $0 == Character(ch) })
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    /// 行内代码与 URL 的区间。
    private static func maskedRanges(
        in line: Substring,
        offsetInText: String.Index,
        of text: String
    ) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []

        // 行内代码：配对的反引号串
        var i = line.startIndex
        while i < line.endIndex {
            guard line[i] == "`" else {
                i = line.index(after: i)
                continue
            }
            let openStart = i
            var n = 0
            while i < line.endIndex, line[i] == "`" {
                n += 1
                i = line.index(after: i)
            }
            let openEnd = i
            // 找等长的结束串
            var j = i
            var found: String.Index? = nil
            while j < line.endIndex {
                if line[j] == "`" {
                    let runStart = j
                    var m = 0
                    while j < line.endIndex, line[j] == "`" {
                        m += 1
                        j = line.index(after: j)
                    }
                    if m == n {
                        found = runStart
                        _ = runStart
                        break
                    }
                } else {
                    j = line.index(after: j)
                }
            }
            if let closeStart = found {
                let closeEnd = line.index(closeStart, offsetBy: n, limitedBy: line.endIndex) ?? line.endIndex
                out.append(openStart..<closeEnd)
                i = closeEnd
            } else {
                // 未闭合：只遮住开头那串
                out.append(openStart..<openEnd)
            }
        }

        // URL：http(s):// 到空白
        var k = line.startIndex
        while let r = line.range(of: "://", range: k..<line.endIndex) {
            // 回退到协议起点
            var s = r.lowerBound
            for _ in 0..<8 {
                if s <= line.startIndex { break }
                let prev = line.index(before: s)
                if line[prev].isLetter { s = prev } else { break }
            }
            var e = r.upperBound
            while e < line.endIndex, !line[e].isWhitespace { e = line.index(after: e) }
            out.append(s..<e)
            k = e
        }

        return out
    }

    private static func isMasked(
        _ index: String.Index,
        _ masked: [Range<String.Index>],
        _ text: String
    ) -> Bool {
        masked.contains { $0.contains(index) }
    }
}
