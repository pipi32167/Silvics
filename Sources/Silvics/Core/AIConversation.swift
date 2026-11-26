import Foundation

/// 用户附到提问里的一段正文。
struct AIQuote: Codable, Equatable {
    var noteID: String
    var noteTitle: String
    var text: String
}

/// 抓回来的一段网页正文。只作为当轮材料，不回灌历史。
struct AIEvidence: Codable, Equatable {
    var url: String
    var title: String
    var text: String
}

/// 会话里的一条记录。
///
/// `role` 有三种：`user`、`assistant`、`clear`。
/// `clear` 是清空标记，只带 `id` 与 `at`，不删文件。
///
/// 元数据跟着消息走：引用、证据、模型名、token 数都在同一条记录里，
/// 跨设备合并后不会丢。
struct AIMessage: Codable, Equatable, Identifiable {
    var id: String
    var at: Int64
    var role: String
    var content: String = ""
    var quote: AIQuote? = nil
    var evidences: [AIEvidence] = []
    var model: String? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil

    static let roleUser = "user"
    static let roleAssistant = "assistant"
    static let roleClear = "clear"

    static func user(
        _ content: String,
        at: Int64 = AIMessage.now(),
        quote: AIQuote? = nil
    ) -> AIMessage {
        AIMessage(id: UUID().uuidString, at: at, role: roleUser, content: content, quote: quote)
    }

    static func assistant(
        _ content: String,
        at: Int64 = AIMessage.now(),
        evidences: [AIEvidence] = [],
        model: String? = nil
    ) -> AIMessage {
        AIMessage(
            id: UUID().uuidString, at: at, role: roleAssistant,
            content: content, evidences: evidences, model: model
        )
    }

    static func clear(at: Int64 = AIMessage.now()) -> AIMessage {
        AIMessage(id: UUID().uuidString, at: at, role: roleClear)
    }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    var isClear: Bool { role == Self.roleClear }
    var isUser: Bool { role == Self.roleUser }
    var isAssistant: Bool { role == Self.roleAssistant }
}

/// 一个笔记（或全局）的会话。落 `<vault>/ai/<note-id>.jsonl`。
enum AIConversation {

    /// 全局会话的 id。没有选中笔记时用它。
    static let globalID = "_global"
    static let dirName = "ai"
    static let fileExtension = "jsonl"

    static func fileName(for noteID: String) -> String {
        let safe = noteID.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(safe).\(fileExtension)"
    }

    static func noteID(fromFileName name: String) -> String? {
        guard name.hasSuffix("." + fileExtension) else { return nil }
        return String(name.dropLast(fileExtension.count + 1))
    }

    // MARK: - JSONL 编解码

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // 稳定输出：同一组消息必得同样字节，manifest 哈希才稳。
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// 编码成 JSONL：一条消息一行，行尾带 `\n`。
    static func encode(_ messages: [AIMessage]) -> String {
        var out = ""
        for message in messages {
            guard let data = try? encoder.encode(message),
                  let line = String(data: data, encoding: .utf8)
            else { continue }
            out += line + "\n"
        }
        return out
    }

    /// 解析 JSONL。坏行跳过并计数，其余照常读。
    static func decode(_ text: String) -> (messages: [AIMessage], badLines: [String]) {
        var messages: [AIMessage] = []
        var bad: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(AIMessage.self, from: data),
                  !message.id.isEmpty, !message.role.isEmpty
            else {
                bad.append(line)
                continue
            }
            messages.append(message)
        }
        return (sort(messages), bad)
    }

    // MARK: - 合并

    /// 按 `at` 升序，同一毫秒按 `id` 排序。顺序稳定，两端算出来一致。
    static func sort(_ messages: [AIMessage]) -> [AIMessage] {
        messages.sorted { a, b in
            a.at != b.at ? a.at < b.at : a.id < b.id
        }
    }

    /// 三方合并。纯函数，不发网络、不读文件。
    ///
    /// 1. 按 `id` 去重，取三份的并集。同 id 内容不同时保留本地。
    /// 2. 按 `at` 升序排。
    /// 3. 找最新的清空标记，丢掉它之前（含同一毫秒）的消息。
    /// 4. 截到会话上限。
    static func merge(base: [AIMessage], local: [AIMessage], remote: [AIMessage]) -> [AIMessage] {
        var byID: [String: AIMessage] = [:]
        for message in remote { byID[message.id] = message }
        for message in base { byID[message.id] = message }
        // 本地最后写入：同 id 冲突时本地优先。
        for message in local { byID[message.id] = message }
        return applyClear(sort(Array(byID.values)))
    }

    /// 用最新的清空标记裁掉之前的消息。标记本身保留，供另一端识别。
    static func applyClear(_ messages: [AIMessage]) -> [AIMessage] {
        guard let latest = messages.filter(\.isClear).max(by: { a, b in
            a.at != b.at ? a.at < b.at : a.id < b.id
        }) else { return trim(messages) }
        return trim(messages.filter { $0.isClear ? $0.id == latest.id : $0.at > latest.at })
    }

    /// 超出上限时丢最早的消息。清空标记与它之后的消息优先保留。
    static func trim(_ messages: [AIMessage]) -> [AIMessage] {
        guard messages.count > AISettings.maxMessages else { return messages }
        return Array(messages.suffix(AISettings.maxMessages))
    }

    /// 当前可见的对话（去掉清空标记）。
    static func visible(_ messages: [AIMessage]) -> [AIMessage] {
        messages.filter { !$0.isClear }
    }
}
