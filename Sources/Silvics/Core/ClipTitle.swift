import Foundation

/// 剪藏标题的来源策略。存在 `ClipSettings`，默认「智能」。
enum ClipTitleStrategy: String, Codable, CaseIterable, Sendable {
    /// 有原文标题或文件名就用，缺失才让模型提炼。
    case smart
    /// 一律让模型按正文重写。
    case alwaysModel
    /// 不调模型：有就用，缺失取正文首行。
    case never

    var label: String {
        switch self {
        case .smart: return "智能"
        case .alwaysModel: return "总是提炼"
        case .never: return "不用模型"
        }
    }
}

/// 剪藏标题的清洗、兜底与去重。
///
/// 剪藏标题不是断言，不能套 `TextNormalizer.validateTitle`；但必须能被 `[[ ]]` 引用，
/// 所以 `[ ] ( )` 要换掉，也不能撞上日记的日期标题。
enum ClipTitle {

    static let maxLength = 60
    static let minLength = 4
    static let fallbackLength = 40

    /// 清洗并保证唯一。
    ///
    /// - Parameters:
    ///   - raw: 原文标题、文件名或模型给出的标题。空串表示没有。
    ///   - source: 站点名或文件名。日期标题与重名时拼在标题后面。
    ///   - body: 正文。`raw` 为空时用来兜底。
    ///   - isTaken: 标题键是否已被别的笔记占用。
    static func finalize(
        raw: String,
        source: String,
        body: String,
        isTaken: (String) -> Bool
    ) -> String {
        var title = clean(raw)
        if title.count < minLength { title = fromBody(body) }
        if title.count < minLength { title = "未命名剪藏 · " + today() }

        let suffix = clean(source)
        if TextNormalizer.isDateLike(title), !suffix.isEmpty {
            title = "\(title) · \(suffix)"
        }
        return uniquify(title, suffix: suffix, isTaken: isTaken)
    }

    /// 去 Markdown 标记、压空白、换掉会破坏 `[[ ]]` 的字符、截断。
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 首行的 Markdown 标记：`# 标题`、`> 引用`、`**粗**`
        while let first = text.first, first == "#" || first == ">" {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = text.replacingOccurrences(of: "[", with: "［")
        text = text.replacingOccurrences(of: "]", with: "］")
        text = text.replacingOccurrences(of: "(", with: "（")
        text = text.replacingOccurrences(of: ")", with: "）")
        if text.count > maxLength {
            text = String(text.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }

    /// 正文兜底标题：第一段非空文字，去掉列表与标题标记。
    static func fromBody(_ body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var text = String(line).trimmingCharacters(in: .whitespaces)
            while let first = text.first, "#>-* ".contains(first) {
                text.removeFirst()
            }
            text = clean(text)
            if text.count < minLength { continue }
            if text.count > fallbackLength {
                text = String(text.prefix(fallbackLength)).trimmingCharacters(in: .whitespaces) + "…"
            }
            return text
        }
        return ""
    }

    /// 重名时追加来源或序号。`isTaken` 只看标题键，大小写与全半角已归一。
    static func uniquify(_ base: String, suffix: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(TextNormalizer.key(base)) { return base }
        var candidate = suffix.isEmpty ? base : "\(base) · \(suffix)"
        if !isTaken(TextNormalizer.key(candidate)) { return candidate }
        var index = 2
        while index < 100 {
            let next = "\(candidate) (\(index))"
            if !isTaken(TextNormalizer.key(next)) { return next }
            index += 1
        }
        return "\(base) · \(today())"
    }

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
