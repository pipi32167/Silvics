import Foundation

/// HTML → 纯文本。自己写，不引第三方解析库。
///
/// 目标不是像素级还原网页，而是拿到能读、能搜索、能交给模型的正文。
/// 顺序：解码 → 去噪 → 选容器 → 块级转换 → 实体解码 → 压空白。
enum ClipExtractor {

    struct Article: Equatable {
        var title: String = ""
        var site: String = ""
        var author: String = ""
        var published: String = ""
        var body: String = ""
    }

    /// 正文短于这个字数时提示可能被登录墙挡住。
    static let minBodyLength = 200

    // MARK: - 解码

    /// 按响应头或 `<meta charset>` 猜编码。顺序 UTF-8 → GB18030 → Latin-1。
    static func decode(_ data: Data, contentType: String? = nil) -> String {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        // GB18030 覆盖 GBK 与 GB2312，中文站点常用。
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        if let text = String(data: data, encoding: gb18030), !text.isEmpty {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 抽取

    static func extract(html raw: String) -> Article {
        var article = Article()
        article.title = metaContent(in: raw, key: "og:title")
            ?? firstMatch(in: raw, pattern: "(?is)<title[^>]*>(.*?)</title>").map(cleanText) ?? ""
        article.site = metaContent(in: raw, key: "og:site_name")
            ?? metaContent(in: raw, key: "application-name") ?? ""
        article.author = metaContent(in: raw, key: "article:author")
            ?? metaContent(in: raw, key: "author") ?? ""
        article.published = metaContent(in: raw, key: "article:published_time") ?? ""

        var html = stripNoise(raw)
        html = pickContainer(html)
        article.body = renderBody(html)
        return article
    }

    /// 只有正文的简化入口。
    static func text(fromHTML raw: String) -> String {
        extract(html: raw).body
    }

    // MARK: - 步骤

    static func stripNoise(_ html: String) -> String {
        let blocks = [
            "script", "style", "noscript", "iframe", "svg", "form",
            "nav", "header", "footer", "aside", "template",
        ]
        var text = html
        for tag in blocks {
            text = replace(text, pattern: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ")
        }
        // 自闭合的 script/style 之类
        text = replace(text, pattern: "(?is)<(script|style|iframe|svg)\\b[^>]*/?>", with: " ")
        return text
    }

    /// 正文容器：`article` → `main` → `body` → 全文。多个候选取文本最长的。
    static func pickContainer(_ html: String) -> String {
        for tag in ["article", "main"] {
            let candidates = matches(html, pattern: "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)>")
            if let longest = candidates.max(by: { plainLength($0) < plainLength($1) }),
               plainLength(longest) >= minBodyLength / 2 {
                return longest
            }
        }
        if let body = matches(html, pattern: "(?is)<body\\b[^>]*>(.*?)</body>")
            .max(by: { plainLength($0) < plainLength($1) }) {
            return body
        }
        return html
    }

    /// 块级标签转 Markdown，剩下的标签去掉，最后解实体、压空白。
    static func renderBody(_ html: String) -> String {
        var text = html

        text = replace(text, pattern: "(?is)<(h1|h2)\\b[^>]*>", with: "\n\n## ")
        text = replace(text, pattern: "(?is)<(h3|h4|h5|h6)\\b[^>]*>", with: "\n\n### ")
        text = replace(text, pattern: "(?is)<li\\b[^>]*>", with: "\n- ")
        text = replace(text, pattern: "(?is)<blockquote\\b[^>]*>", with: "\n> ")
        text = replace(text, pattern: "(?is)<pre\\b[^>]*>", with: "\n```\n")
        text = replace(text, pattern: "(?is)</pre>", with: "\n```\n")
        text = replace(text, pattern: "(?is)<br\\s*/?>", with: "\n")
        text = replace(text, pattern: "(?is)</(p|div|section|article|blockquote|li|tr|h1|h2|h3|h4|h5|h6|ul|ol|table|main)>", with: "\n\n")
        text = replace(text, pattern: "(?is)<[^>]+>", with: "")

        text = decodeEntities(text)
        return normalizeWhitespace(text)
    }

    // MARK: - 元信息

    static func metaContent(in html: String, key: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        // property/content 两种顺序都要认
        let patterns = [
            "(?is)<meta[^>]*property=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"']*)[\"']",
            "(?is)<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*property=[\"']\(escaped)[\"']",
            "(?is)<meta[^>]*name=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"']*)[\"']",
            "(?is)<meta[^>]*content=[\"']([^\"']*)[\"'][^>]*name=[\"']\(escaped)[\"']",
        ]
        for pattern in patterns {
            if let value = firstMatch(in: html, pattern: pattern) {
                let cleaned = decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    // MARK: - 文本工具

    static func cleanText(_ raw: String) -> String {
        normalizeWhitespace(decodeEntities(replace(raw, pattern: "(?is)<[^>]+>", with: "")))
    }

    static func normalizeWhitespace(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .joined(separator: " ")
            lines.append(trimmed)
        }
        var out: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var text = raw
        text = replace(text, pattern: "&#x([0-9A-Fa-f]+);") { hex in
            guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        text = replace(text, pattern: "&#([0-9]+);") { digits in
            guard let value = UInt32(digits), let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…",
            "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
            "middot": "·", "times": "×", "copy": "©", "reg": "®",
            "deg": "°", "plusmn": "±", "euro": "€", "pound": "£",
        ]
        return replace(text, pattern: "&([A-Za-z]+);") { name in named[name.lowercased()] }
    }

    // MARK: - 正则包装

    private static func plainLength(_ html: String) -> Int {
        cleanText(html).count
    }

    private static func matches(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        matches(text, pattern: pattern).first
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// 把捕获组交给闭包决定替换成什么。返回 nil 表示保持原样。
    private static func replace(
        _ text: String,
        pattern: String,
        transform: (String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = text
        // 从后往前替换，避免偏移失效
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { continue }
            guard let replacement = transform(String(text[r])) else { continue }
            if let swiftRange = Range(match.range, in: out) {
                out.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return out
    }
}
