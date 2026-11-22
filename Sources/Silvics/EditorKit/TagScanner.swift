import Foundation

/// 正文里扫出的一个 `#标签`。
struct TagHit: Equatable {
    /// 标签名，不含 `#`。
    var name: String
    /// 整段 `#标签` 在原文中的区间（UTF-16）。给高亮与命中判定用。
    var range: NSRange
}

/// `#标签` 扫描器。
///
/// 规则：
/// - `#` 后必须紧跟至少一个合法字符，所以 `# 标题`（ATX 标题）不算标签。
/// - 标签字符：字母、数字（含中文）、`_`、`-`、`/`。
/// - 跳过围栏代码块、行内代码、`[[ ]]` 内部、URL 内部。
/// - 前后不能紧贴字母数字，避免 `a#b` 这类误判。
///
/// 不用正则引擎：扫描可以在每次保存时跑，线性一遍足够，
/// 而且正则的 Unicode 属性边界在中文标点上容易踩坑。
enum TagScanner {

    static let maxLength = 32

    static func scan(_ text: String) -> [TagHit] {
        guard text.contains("#") else { return [] }

        let excluded = excludedRanges(in: text)
        var hits: [TagHit] = []
        var seen = Set<String>()

        var utf16Offset = 0
        var previous: Character?

        for character in text {
            let length = character.utf16.count
            defer {
                utf16Offset += length
                previous = character
            }

            guard character == "#" else { continue }

            // `#` 前面紧贴字母数字或空格的，是别的东西（颜色值、C# 之类）
            if let previous, previous.isLetter || previous.isNumber { continue }

            // 往后取标签体
            var name = ""
            var consumed = 0

            // 找 `#` 在字符串中的下标：用 UTF-16 偏移换算
            guard let hashIndex = Self.index(ofUTF16Offset: utf16Offset, in: text) else { continue }
            var scan = text.index(after: hashIndex)
            while scan < text.endIndex, name.count < maxLength {
                let ch = text[scan]
                guard isTagCharacter(ch) else { break }
                name.append(ch)
                consumed += ch.utf16.count
                scan = text.index(after: scan)
            }

            guard !name.isEmpty else { continue }

            let range = NSRange(location: utf16Offset, length: 1 + consumed)
            guard !overlaps(range, excluded) else { continue }

            let key = name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            hits.append(TagHit(name: name, range: range))
        }

        return hits
    }

    static func isTagCharacter(_ ch: Character) -> Bool {
        if ch == "_" || ch == "-" || ch == "/" { return true }
        if ch.isLetter || ch.isNumber { return true }
        return false
    }

    // MARK: - 排除区

    private static func excludedRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let spans = MarkdownStyler.analyze(text)
        ranges.append(contentsOf: spans.codeBlocks)
        ranges.append(contentsOf: spans.inlineCodes)
        ranges.append(contentsOf: WikiScanner.scan(text).map { $0.nsRange(in: text) })
        ranges.append(contentsOf: urlRanges(in: text))
        return ranges
    }

    /// `http(s)://` 到空白的区间。
    private static func urlRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let ns = text as NSString
        var searchStart = 0
        while searchStart < ns.length {
            let found = ns.range(of: "://", options: [], range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard found.location != NSNotFound else { break }

            var start = found.location
            while start > 0 {
                let prev = ns.character(at: start - 1)
                guard let scalar = Unicode.Scalar(prev), Character(scalar).isLetter else { break }
                start -= 1
            }
            var end = NSMaxRange(found)
            while end < ns.length {
                let ch = ns.character(at: end)
                if let scalar = Unicode.Scalar(ch), Character(scalar).isWhitespace { break }
                end += 1
            }
            ranges.append(NSRange(location: start, length: end - start))
            searchStart = end
        }
        return ranges
    }

    private static func overlaps(_ range: NSRange, _ excluded: [NSRange]) -> Bool {
        for ex in excluded where ex.length > 0 {
            if NSIntersectionRange(range, ex).length > 0 { return true }
        }
        return false
    }

    /// UTF-16 偏移 → `String.Index`。避免对每个 `#` 都从头遍历。
    private static func index(ofUTF16Offset offset: Int, in text: String) -> String.Index? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        return String.Index(utf16Offset: offset, in: text)
    }
}
