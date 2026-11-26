import Foundation

/// HTML → 纯文本。自己写，不引第三方解析库。
///
/// 目标不是像素级还原网页，而是拿到「文章正文」：能读、能搜索、能交给模型。
/// 顺序：解码 → 去噪（结构 + 类名 + 链接密度）→ 选正文容器 → 块级转换 → 收尾。
///
/// 只靠正则删不干净：导航、作者卡、分享条、相关阅读、评论区往往在同一个
/// `<article>` 里。这里用一个最小 HTML 树，先剪枝再渲染。
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

        let root = HTMLTree.parse(raw)
        HTMLTree.prune(root)
        let container = HTMLTree.chooseContainer(root)
        article.body = postProcess(render(container))
        return article
    }

    /// 只有正文的简化入口。
    static func text(fromHTML raw: String) -> String {
        extract(html: raw).body
    }

    // MARK: - 渲染

    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "main", "figure", "figcaption",
        "table", "thead", "tbody", "tfoot", "dl", "dt", "dd", "center",
    ]

    private static func render(_ node: HTMLTree.Node) -> String {
        var out = ""
        func walk(_ current: HTMLTree.Node) {
            switch current.kind {
            case .text(let text):
                out += text
            case .element(let name, _):
                switch name {
                case "br":
                    out += "\n"
                case "h1", "h2":
                    out += "\n\n## "
                    walkChildren(current, walk)
                    out += "\n\n"
                case "h3", "h4", "h5", "h6":
                    out += "\n\n### "
                    walkChildren(current, walk)
                    out += "\n\n"
                case "li":
                    out += "\n- "
                    walkChildren(current, walk)
                case "ul", "ol":
                    out += "\n"
                    walkChildren(current, walk)
                    out += "\n"
                case "blockquote":
                    out += "\n> "
                    walkChildren(current, walk)
                    out += "\n"
                case "pre":
                    out += "\n```\n"
                    out += current.textContent()
                    out += "\n```\n"
                case "tr":
                    walkChildren(current, walk)
                    out += "\n"
                case "td", "th":
                    walkChildren(current, walk)
                    out += " "
                default:
                    if blockTags.contains(name) {
                        walkChildren(current, walk)
                        out += "\n\n"
                    } else {
                        walkChildren(current, walk)
                    }
                }
            }
        }
        walk(node)
        return out
    }

    private static func walkChildren(_ node: HTMLTree.Node, _ walk: (HTMLTree.Node) -> Void) {
        for child in node.children { walk(child) }
    }

    /// 行级收尾：解实体、去「[编辑]」、去社交/版权行、截掉相关阅读段、压空行。
    static func postProcess(_ raw: String) -> String {
        var text = decodeEntities(raw)
        text = text.replacingOccurrences(of: "\u{00a0}", with: " ")

        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .joined(separator: " ")
                    .replacingOccurrences(of: "[编辑]", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }

        // 只剩标点或分隔符的行没有信息。
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !(trimmed.isEmpty == false && ["-", "·", "|", "—", "–"].contains(trimmed))
        }

        // 站点自带的分享、关注、版权、推荐语。只在短行里删，避免误伤正文句子。
        let noisePhrases = [
            "微信扫码", "扫码分享", "分享到微博", "点击下方", "复制链接", "分享收藏",
            "责任编辑", "本文责编", "实习生", "校对：", "下载少数派", "关注 少数派",
            "公众号", "官方店铺", "位派友", "已充电", "利益相关声明", "Matrix 首页推荐",
            "文章代表作者个人观点", "未经授权", "转载请注明", "点击关注", "订阅我们",
            "Matrix 是少数派的写作社区", "上一页", "下一页", "上一篇", "下一篇",
            "上一节", "下一节", "返回顶部",
        ]
        // 明确的站点声明/推广语，长短都删；其余噪声只删短行，避免误伤正文。
        let strongNoisePhrases = [
            "Matrix 是少数派的写作社区", "文章代表作者个人观点", "利益相关声明：",
            "微信扫码分享", "点击下方按钮可复制链接", "分享收藏举报",
        ]
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            if strongNoisePhrases.contains(where: { trimmed.contains($0) }) { return false }
            guard trimmed.count < 80 else { return true }
            return !noisePhrases.contains { trimmed.contains($0) }
        }

        // 开头是站点推荐语、编者按或声明时，跳到下一个标题，别把推广段落当正文。
        let leadNoise = ["Matrix 首页推荐", "编者按", "编辑按", "利益相关声明", "特别声明", "推荐语", "写在前面"]
        if let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let firstLine = lines[firstIndex].trimmingCharacters(in: .whitespaces)
            let bare = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#> -*\t"))
            if leadNoise.contains(where: { bare == $0 || bare.hasPrefix($0) }),
               let nextHeading = lines[(firstIndex + 1)...].firstIndex(where: {
                   $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
               }) {
                lines = Array(lines[nextHeading...])
            }
        }

        // 相关阅读 / 评论区之后的内容不是文章正文。
        let stopHeadings = [
            "相关阅读", "推荐阅读", "延伸阅读", "相关文章", "热门评论", "评论区",
            "猜你喜欢", "你可能还喜欢", "更多阅读", "本文标签", "版权声明",
            "免责声明", "特别声明", "本文来自", "往期推荐",
        ]
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let bare = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#> -*\t"))
            guard trimmed.hasPrefix("#") || bare.count <= 12 else { continue }
            if stopHeadings.contains(where: { bare == $0 || bare.hasPrefix($0 + " ") || bare.hasPrefix($0 + "：") }) {
                lines = Array(lines[0..<index])
                break
            }
        }

        var out: [String] = []
        var blankRun = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - 最小 HTML 树

/// 只做「够剪枝」的解析：标签、属性、文本、层级。
/// 不实现命名空间、CDATA、模板语法；解析不了的内容按文本或丢弃处理。
private enum HTMLTree {

    final class Node {
        enum Kind {
            case element(name: String, attrs: [String: String])
            case text(String)
        }

        var kind: Kind
        var children: [Node] = []
        weak var parent: Node?

        init(_ kind: Kind) { self.kind = kind }

        var name: String? {
            if case .element(let name, _) = kind { return name }
            return nil
        }

        var isElement: Bool { name != nil }

        var attrs: [String: String] {
            if case .element(_, let attrs) = kind { return attrs }
            return [:]
        }

        /// class + id，统一小写。剪枝只看这一个串。
        var signature: String {
            ((attrs["class"] ?? "") + " " + (attrs["id"] ?? "")).lowercased()
        }

        func append(_ child: Node) {
            child.parent = self
            children.append(child)
        }

        /// 原始文本（未解实体）。用于 `<pre>` 与剪枝评估。
        func textContent() -> String {
            switch kind {
            case .text(let text):
                return text
            case .element:
                return children.map { $0.textContent() }.joined()
            }
        }

        var textLength: Int { textContent().count }

        /// 后代里的链接数与链接文字长度。链接农场靠它识别。
        func anchorStats() -> (links: Int, anchorText: Int) {
            var links = 0
            var anchorText = 0
            func walk(_ node: Node) {
                if node.name == "a" {
                    links += 1
                    anchorText += node.textLength
                }
                for child in node.children { walk(child) }
            }
            walk(self)
            return (links, anchorText)
        }

        func paragraphCount() -> Int {
            var count = 0
            func walk(_ node: Node) {
                if node.name == "p", node.textLength > 20 { count += 1 }
                for child in node.children { walk(child) }
            }
            walk(self)
            return count
        }
    }

    // MARK: 解析

    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// 这些标签的内容对正文没有价值，解析时整段跳过。
    private static let skipContentTags: Set<String> = [
        "script", "style", "noscript", "iframe", "svg", "template", "form",
        "textarea", "select", "canvas", "audio", "video",
    ]

    static func parse(_ html: String) -> Node {
        let root = Node(.element(name: "#root", attrs: [:]))
        var stack: [Node] = [root]
        let bytes = Array(html.utf8)
        var index = 0
        var textStart = 0

        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            let text = String(decoding: bytes[textStart..<end], as: UTF8.self)
            if !text.isEmpty { stack[stack.count - 1].append(Node(.text(text))) }
        }

        while index < bytes.count {
            guard bytes[index] == 0x3C else { index += 1; continue }
            flushText(upTo: index)

            // 注释
            if index + 3 < bytes.count,
               bytes[index + 1] == 0x21, bytes[index + 2] == 0x2D, bytes[index + 3] == 0x2D {
                if let end = find(bytes, pattern: [0x2D, 0x2D, 0x3E], from: index + 4) {
                    index = end + 3
                } else {
                    index = bytes.count
                }
                textStart = index
                continue
            }

            // doctype / 处理指令
            if index + 1 < bytes.count, bytes[index + 1] == 0x21 || bytes[index + 1] == 0x3F {
                if let end = find(bytes, pattern: [0x3E], from: index + 2) {
                    index = end + 1
                } else {
                    index = bytes.count
                }
                textStart = index
                continue
            }

            // 结束标签
            if index + 2 < bytes.count, bytes[index + 1] == 0x2F {
                var cursor = index + 2
                let name = readName(bytes, &cursor).lowercased()
                if let end = find(bytes, pattern: [0x3E], from: cursor) {
                    index = end + 1
                } else {
                    index = bytes.count
                }
                if !name.isEmpty, let position = stack.lastIndex(where: { $0.name == name }) {
                    stack.removeSubrange(position..<stack.count)
                }
                textStart = index
                continue
            }

            // 开始标签
            var cursor = index + 1
            let name = readName(bytes, &cursor).lowercased()
            guard !name.isEmpty else {
                index += 1
                textStart = index
                continue
            }

            var attrs: [String: String] = [:]
            var selfClosing = false
            while cursor < bytes.count {
                skipSpaces(bytes, &cursor)
                guard cursor < bytes.count else { break }
                if bytes[cursor] == 0x3E { cursor += 1; break }
                if bytes[cursor] == 0x2F { selfClosing = true; cursor += 1; continue }

                let keyStart = cursor
                while cursor < bytes.count,
                      !isSpace(bytes[cursor]),
                      bytes[cursor] != 0x3D,
                      bytes[cursor] != 0x3E,
                      bytes[cursor] != 0x2F {
                    cursor += 1
                }
                let key = String(decoding: bytes[keyStart..<cursor], as: UTF8.self).lowercased()
                skipSpaces(bytes, &cursor)

                var value = ""
                if cursor < bytes.count, bytes[cursor] == 0x3D {
                    cursor += 1
                    skipSpaces(bytes, &cursor)
                    if cursor < bytes.count, bytes[cursor] == 0x22 || bytes[cursor] == 0x27 {
                        let quote = bytes[cursor]
                        cursor += 1
                        let valueStart = cursor
                        while cursor < bytes.count, bytes[cursor] != quote { cursor += 1 }
                        value = String(decoding: bytes[valueStart..<min(cursor, bytes.count)], as: UTF8.self)
                        if cursor < bytes.count { cursor += 1 }
                    } else {
                        let valueStart = cursor
                        while cursor < bytes.count, !isSpace(bytes[cursor]), bytes[cursor] != 0x3E {
                            cursor += 1
                        }
                        value = String(decoding: bytes[valueStart..<cursor], as: UTF8.self)
                    }
                }
                if !key.isEmpty { attrs[key] = value }
            }

            index = cursor

            // 脚本、样式等整段跳过，不建节点。
            if skipContentTags.contains(name) {
                if let close = findClosing(bytes, name: name, from: index),
                   let end = find(bytes, pattern: [0x3E], from: close) {
                    index = end + 1
                } else {
                    index = bytes.count
                }
                textStart = index
                continue
            }

            let node = Node(.element(name: name, attrs: attrs))
            stack[stack.count - 1].append(node)
            if !selfClosing && !voidTags.contains(name) {
                stack.append(node)
            }
            textStart = index
        }

        flushText(upTo: bytes.count)
        return root
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func skipSpaces(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
    }

    private static func readName(_ bytes: [UInt8], _ index: inout Int) -> String {
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            let isNameByte = (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x5F || byte == 0x3A
            if !isNameByte { break }
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private static func find(_ bytes: [UInt8], pattern: [UInt8], from start: Int) -> Int? {
        guard !pattern.isEmpty, start <= bytes.count - pattern.count else { return nil }
        var index = start
        while index <= bytes.count - pattern.count {
            if bytes[index] == pattern[0] {
                var matched = true
                for offset in 1..<pattern.count where bytes[index + offset] != pattern[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    /// 找 `</name`（大小写不敏感），返回 `<` 的位置。
    private static func findClosing(_ bytes: [UInt8], name: String, from start: Int) -> Int? {
        let target = Array(name.utf8)
        var index = start
        while index + target.count + 1 < bytes.count {
            if bytes[index] == 0x3C, bytes[index + 1] == 0x2F {
                var matched = true
                for offset in 0..<target.count {
                    let byte = bytes[index + 2 + offset]
                    let lower = (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
                    if lower != target[offset] { matched = false; break }
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: 剪枝

    private static let dropTags: Set<String> = [
        "script", "style", "noscript", "iframe", "svg", "form", "nav", "header",
        "footer", "aside", "dialog", "button", "input", "select", "textarea",
        "canvas", "video", "audio", "source", "track", "object", "embed",
        "head", "title", "meta", "link", "base",
    ]

    /// 类名/id 里出现这些词，基本是站点框架而不是文章。
    private static let noiseTokens: Set<String> = [
        "nav", "navbar", "menu", "menubar", "header", "footer", "sidebar", "aside",
        "comment", "comments", "related", "recommend", "recommendation", "share",
        "social", "subscribe", "newsletter", "advert", "advertisement", "ads", "ad",
        "banner", "breadcrumb", "breadcrumbs", "pagination", "pager", "toolbar",
        "modal", "popup", "cookie", "copyright", "editsection", "directory",
        "catalog", "toc", "sticky", "qrcode", "download", "login", "signup",
    ]

    private static let noisePhrases = [
        "backtotop", "readmore", "relatedposts", "postcomments", "articlefooter",
        "articleheader", "articletoolbar", "sitesearch", "userbar", "topbar",
        "sharebar", "authorcard", "authorinfo", "commentlist", "promobox",
    ]

    private static let contentHints = [
        "articlebody", "articlecontent", "articlemaincontent", "postcontent",
        "entrycontent", "markdownbody", "richmedia", "mwparseroutput",
        "contentbody", "storybody", "articletext", "postbody", "blogcontent",
        "detailcontent", "contentmain", "maincontent", "textcontent",
        "articlecontainer", "articlewrapper", "contentarticle",
    ]

    /// 结构性根节点不按类名剪：`<html>` / `<body>` 的 class 里常有一长串
    /// 「in-header」「sticky」之类的特性开关，按词匹配会把整页误删。
    private static let protectedTags: Set<String> = ["html", "body", "#root", "main", "article"]

    static func prune(_ node: Node) {
        var kept: [Node] = []
        for child in node.children {
            guard child.isElement else {
                kept.append(child)
                continue
            }
            let name = child.name ?? ""
            if dropTags.contains(name) { continue }

            let isProtected = protectedTags.contains(name)
            // 超大容器多半是正文本身，不按类名误杀；真正的框架块通常不大。
            if !isProtected, child.textLength < 3000, isNoiseSignature(child.signature) { continue }

            prune(child)

            if !isProtected, isLinkFarm(child) { continue }
            if child.textLength == 0, !["br", "img", "hr"].contains(name) { continue }
            kept.append(child)
        }
        node.children = kept
    }

    private static func isNoiseSignature(_ signature: String) -> Bool {
        guard !signature.isEmpty else { return false }
        let tokens = signature.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if tokens.contains(where: { noiseTokens.contains($0) }) { return true }
        let compact = signature.filter { $0.isLetter || $0.isNumber }
        return noisePhrases.contains { compact.contains($0) }
    }

    private static func isContentSignature(_ signature: String) -> Bool {
        guard !signature.isEmpty else { return false }
        let compact = signature.filter { $0.isLetter || $0.isNumber }
        return contentHints.contains { compact.contains($0) }
    }

    /// 链接农场：链接多、链接文字占比高、整体又不长。tag 云、相关推荐列表都命不中正文。
    private static func isLinkFarm(_ node: Node) -> Bool {
        let name = node.name ?? ""
        guard ["div", "section", "ul", "ol", "table", "p", "li"].contains(name) else { return false }
        let stats = node.anchorStats()
        let length = node.textLength
        guard stats.links >= 3, length > 0 else { return false }
        if stats.links >= 10, length < 2000 { return true }
        if name == "p" || name == "li" {
            return stats.links >= 3 && stats.anchorText * 10 >= length * 8 && length < 400
        }
        return stats.anchorText * 10 >= length * 6 && length < 1200
    }

    static func chooseContainer(_ root: Node) -> Node {
        var all: [Node] = []
        func collect(_ node: Node) {
            if node.isElement { all.append(node) }
            for child in node.children { collect(child) }
        }
        collect(root)

        func score(_ node: Node) -> Int {
            node.textLength + node.paragraphCount() * 80
        }

        let hinted = all.filter { isContentSignature($0.signature) && $0.textLength >= 100 }
        if let best = hinted.max(by: { score($0) < score($1) }) { return best }

        let structural = all.filter { ["article", "main", "body"].contains($0.name ?? "") }
        if let best = structural.max(by: { score($0) < score($1) }), score(best) >= 100 { return best }

        let blocks = all.filter { ["div", "section", "td"].contains($0.name ?? "") }
        if let best = blocks.max(by: { score($0) < score($1) }), score(best) >= 200 { return best }

        return root
    }
}
