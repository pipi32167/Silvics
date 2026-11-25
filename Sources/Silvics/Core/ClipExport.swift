import Foundation

/// 剪藏导出。一条一个 `.md`，frontmatter 与 vault 文件一致，外部编辑器能直接读。
///
/// 这是「同步剪藏」关掉时的备份手段：手动导出到一个目录，换机器再拖回来。
enum ClipExport {

    /// 单篇的 Markdown 文本。复用 vault 的稳定序列化。
    static func markdown(_ note: Note) -> String {
        VaultFormat.encode(NoteWriter.vaultNote(
            note,
            metadata: (aliases: [], dismissed: [], )
        ))
    }

    /// 文件名：标题清洗后最多 40 字，重名加序号。避免 `/` 与 `:`。
    static func fileName(for note: Note, index: Int? = nil) -> String {
        var base = note.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.count > 40 { base = String(base.prefix(40)) }
        if base.isEmpty { base = note.id }
        if let index { return "\(base)-\(index).md" }
        return "\(base).md"
    }

    /// 写一篇到目录。返回写出的文件 URL。
    @discardableResult
    static func write(_ note: Note, to directory: URL, index: Int? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: note, index: index))
        try Data(markdown(note).utf8).write(to: url, options: .atomic)
        return url
    }
}
