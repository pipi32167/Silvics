import Foundation

/// 一处无法自动合并的正文冲突。
///
/// 只装合并需要的东西：三方正文与标题。元数据（别名、忽略、时间）由 `VaultSync` 自己合。
struct VaultConflict: Identifiable, Equatable {
    var noteId: String
    var title: String
    var base: String
    var ours: String
    var theirs: String

    var id: String { noteId }

    /// 差异摘要：用于列表里给用户一眼看规模。
    var sizeHint: String {
        "本机 \(ours.count) 字 · 远端 \(theirs.count) 字"
    }
}

/// 用 LLM 合并冲突正文。
///
/// 约束（写进提示词，也写进校验）：
/// - 只输出合并后的 Markdown 正文，不解释、不加代码围栏、不写 `<<<<<<<`。
/// - 保留 `[[双链]]` 与 `#标签` 原样。
/// - 两边说法冲突时保留更具体的一条，并在末尾用「待定：」列出无法取舍的点。
enum ConflictResolver {

    static let systemPrompt = """
    你在帮一个笔记应用合并同一篇 Markdown 笔记的两份改动。规则：
    1. 只输出合并后的正文，不要任何解释、前言、代码围栏。
    2. 不用冲突标记（<<<<<<<、=======、>>>>>>>）。
    3. 保留两边新增的内容与顺序；同一句话只出现一次。
    4. `[[双链]]`、`[[目标|显示名]]`、`#标签` 原样保留，不要改标题。
    5. 两边说法矛盾且无法取舍时，保留更具体的一条，并在最后另起一行写「待定：<一句话说明>」。
    6. 输入里的「标题：」与【共同基线】【本机版本】【远端版本】只是分隔标记，输出里一律不得出现。
    7. 没有冲突的行必须逐字原样保留，包括行首的「第一段：」这类前缀与缩进；只改冲突的那几行。
    """

    static func userPrompt(for conflict: VaultConflict) -> String {
        """
        标题：\(conflict.title)

        【共同基线】
        \(conflict.base.isEmpty ? "（无基线，这是首次同步）" : conflict.base)

        【本机版本】
        \(conflict.ours)

        【远端版本】
        \(conflict.theirs)
        """
    }

    static func messages(for conflict: VaultConflict) -> [ChatMessage] {
        [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt(for: conflict)),
        ]
    }

    /// 去掉模型爱加的外壳：代码围栏、前言，以及被照抄回来的分隔标记。
    static func clean(_ raw: String, title: String? = nil) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 整体被 ``` 包住
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n")
        }

        // 「以下是合并结果：」这类前言
        let prefixes = ["以下是合并后的正文：", "以下是合并结果：", "合并结果：", "合并后的正文："]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        // 模型有时会把输入里的分隔标记照抄回来，逐行丢掉。
        let scaffolds = ["【共同基线】", "【本机版本】", "【远端版本】", "【合并结果】"]
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if scaffolds.contains(trimmed) { continue }
            if let title, trimmed == "标题：" + title { continue }
            kept.append(line)
        }
        text = kept.joined(separator: "\n")

        // 丢掉开头因去标记留下的空行
        while text.hasPrefix("\n") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 返回 nil 表示通过，否则是给用户看的拒绝原因。
    static func validate(_ text: String, conflict: VaultConflict) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "模型返回空内容" }
        if trimmed.contains("<<<<<<<") || trimmed.contains(">>>>>>>") || trimmed.contains("=======") {
            return "模型返回了冲突标记，已拒绝"
        }
        if trimmed.hasPrefix("```") { return "模型返回了代码围栏，已拒绝" }
        let limit = max(conflict.ours.count, conflict.theirs.count) * 3 + 400
        if trimmed.count > limit { return "合并结果异常长（\(trimmed.count) 字），已拒绝" }
        if trimmed == conflict.ours { return "合并结果与本机版本相同，未改动" }
        return nil
    }

    /// 跑一次合并。失败时返回中文原因。
    static func resolve(
        _ conflict: VaultConflict,
        provider: ProviderConfig,
        key: String,
        session: URLSession = .shared
    ) async -> Result<String, LLMError> {
        let result = await ChatClient.complete(
            config: provider,
            key: key,
            messages: messages(for: conflict),
            maxTokens: max(800, min(4000, conflict.ours.count + conflict.theirs.count + 400)),
            session: session
        )

        switch result {
        case .failure(let error):
            return .failure(error)
        case .success(let raw):
            let text = clean(raw, title: conflict.title)
            if let reason = validate(text, conflict: conflict) {
                return .failure(LLMError(message: reason))
            }
            return .success(text)
        }
    }
}
