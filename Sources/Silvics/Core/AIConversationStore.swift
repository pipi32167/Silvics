import Foundation

/// 会话文件的读写。落 `<vault>/ai/*.jsonl`，跟着 vault 同步。
///
/// 写入是「整篇原子写」：文件小（上限 200 KB），比追加更安全，
/// 断电或同步中断也不会留下半行。
struct AIConversationStore {

    /// vault 根目录。换 vault 时跟着变。
    var vaultURL: URL

    init(vaultURL: URL) {
        self.vaultURL = vaultURL
    }

    var directoryURL: URL {
        vaultURL.appendingPathComponent(AIConversation.dirName, isDirectory: true)
    }

    func fileURL(noteID: String) -> URL {
        directoryURL.appendingPathComponent(AIConversation.fileName(for: noteID))
    }

    // MARK: - 读

    /// 读一个会话。坏行跳过并计数，不阻塞加载。
    func load(noteID: String) -> (messages: [AIMessage], badLines: Int) {
        let url = fileURL(noteID: noteID)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return ([], 0) }
        let decoded = AIConversation.decode(text)
        return (decoded.messages, decoded.badLines.count)
    }

    /// 读全部会话的文件名 → 内容，供导出与校验用。
    func loadAll() -> [String: [AIMessage]] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return [:]
        }
        var out: [String: [AIMessage]] = [:]
        for name in names {
            guard let noteID = AIConversation.noteID(fromFileName: name) else { continue }
            out[noteID] = load(noteID: noteID).messages
        }
        return out
    }

    // MARK: - 写

    /// 整篇原子写。内容没变时一个字节都不碰（幂等，git 里不会天天全量 diff）。
    /// - Returns: 是否真的写了。
    @discardableResult
    func save(_ messages: [AIMessage], noteID: String) throws -> Bool {
        let url = fileURL(noteID: noteID)
        let text = AIConversation.encode(AIConversation.trim(messages))
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        // 内容没变时 `writeAtomic` 自己会跳过，不用在这里再比一次。
        return try VaultFormat.writeAtomic(Data(text.utf8), to: url)
    }

    /// 追加一条。读整个文件再写回：文件小，换来原子与幂等。
    ///
    /// 追加后立即按最新清空标记裁剪，否则清空后再追加会把旧消息带回来。
    @discardableResult
    func append(_ message: AIMessage, noteID: String) throws -> [AIMessage] {
        let existing = load(noteID: noteID).messages
        let merged = AIConversation.applyClear(AIConversation.sort(existing + [message]))
        try save(merged, noteID: noteID)
        return merged
    }

    /// 清空：写一条清空标记，不删文件。删文件会被另一台的追加复活。
    @discardableResult
    func clear(noteID: String, at: Int64 = AIMessage.now()) throws -> [AIMessage] {
        try append(.clear(at: at), noteID: noteID)
    }

    /// 删除整个会话文件。只在用户明确要求「删除会话」时调用。
    func remove(noteID: String) throws {
        let url = fileURL(noteID: noteID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - 合并

    /// 把磁盘上的远端版本与本地内存版本三方合并。
    ///
    /// `base` 取「上次同步时读到的那份」，缺省空数组。
    /// 合并结果写回磁盘，并把结果返回给调用方刷新界面。
    @discardableResult
    func mergeAndSave(
        noteID: String,
        local: [AIMessage],
        base: [AIMessage] = []
    ) throws -> [AIMessage] {
        let remote = load(noteID: noteID).messages
        let merged = AIConversation.merge(base: base, local: local, remote: remote)
        try save(merged, noteID: noteID)
        return merged
    }
}
