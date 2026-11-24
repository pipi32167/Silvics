import Foundation
import GRDB

/// 导入结果。
struct VaultImportReport: Equatable {
    var inserted = 0
    var updated = 0
    var unchanged = 0
    /// 标题被另一个 id 占用。不自动合并，交给人。
    var titleConflicts: [String] = []
    var applied: [String] = []
}

/// vault 与数据库之间的搬运。备份、恢复、同步共用。
extension GRDBNoteRepository {

    // MARK: - 文件位置

    /// 一篇笔记在 vault 里的文件。
    func vaultFileURL(for id: String) -> URL {
        vaultURL
            .appendingPathComponent(VaultFormat.notesDir, isDirectory: true)
            .appendingPathComponent(VaultFormat.fileName(for: id))
    }

    /// 别名与已忽略的提及。只存在库里，encode 前必须取出来，否则写进文件就丢了。
    func vaultMetadata(for noteId: String) throws -> (aliases: [String], dismissed: [String]) {
        try db.reader.read { conn in
            let aliases = try String.fetchAll(
                conn,
                sql: "SELECT name FROM alias WHERE noteId = ? ORDER BY name",
                arguments: [noteId]
            )
            let dismissed = try String.fetchAll(
                conn,
                sql: "SELECT targetId FROM mention WHERE noteId = ? AND dismissed = 1 ORDER BY targetId",
                arguments: [noteId]
            )
            return (aliases, dismissed)
        }
    }

    /// 直接读 vault 目录。与 `VaultSync.readVaultNotes` 同一套规则，只是不需要设置对象。
    func vaultNotesOnDisk() throws -> [VaultFormat.Note] {
        let dir = vaultURL.appendingPathComponent(VaultFormat.notesDir, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var notes: [VaultFormat.Note] = []
        for name in names.sorted() where name.hasSuffix(".md") {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let note = try? VaultFormat.decode(text) else { continue }
            notes.append(note)
        }
        return notes
    }

    // MARK: - 索引过期标记

    func metaValue(_ key: String) throws -> String? {
        try db.reader.read { conn in
            try String.fetchOne(conn, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    func setMetaValue(_ key: String, _ value: String) throws {
        try db.writer.write { conn in
            try conn.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    /// 上次保存写完了文件但没写完索引。库是索引，可以从文件重算。
    func isIndexDirty() throws -> Bool {
        try metaValue("indexDirty") == "1"
    }

    func setIndexDirty(_ dirty: Bool) throws {
        try setMetaValue("indexDirty", dirty ? "1" : "0")
    }

    // MARK: - 启动自愈

    /// 老库第一次升级到「文件是真相」：库里已有笔记、vault 里还没有文件时，
    /// 先把库全量写一份到 vault（只写不删），之后删库才能重建。只做一次。
    @discardableResult
    func seedVaultIfNeeded() throws -> String? {
        guard try metaValue("vaultSeeded") != "1" else { return nil }
        let noteCount = try db.reader.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM note") ?? 0
        }
        guard noteCount > 0, try vaultNotesOnDisk().isEmpty else {
            try setMetaValue("vaultSeeded", "1")
            return nil
        }

        var settings = SyncSettings()
        settings.vaultPath = vaultURL.path
        let written = try VaultSync(repo: self, settings: settings).exportAll()
        try setMetaValue("vaultSeeded", "1")
        return "已把库里 \(noteCount) 篇写入 vault（\(written) 个文件）"
    }

    /// 启动时自愈：库空了，或上次索引没写完，就拿 vault 里的文件重建。
    ///
    /// 返回给用户看的一行说明；不需要修时返回 `nil`。
    /// 这里是「删掉 silvics.sqlite 也能起来」的落地处。
    @discardableResult
    func repairFromVaultIfNeeded() throws -> String? {
        let noteCount = try db.reader.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM note") ?? 0
        }
        let dirty = try isIndexDirty()
        guard noteCount == 0 || dirty else { return nil }

        let disk = try vaultNotesOnDisk()
        guard !disk.isEmpty else {
            // vault 没有文件。库空就是真的空；索引脏就从库里的正文重算。
            guard noteCount > 0 else {
                try setIndexDirty(false)
                return nil
            }
            try rebuildAllIndexes()
            try setIndexDirty(false)
            return "索引已从正文重算（\(noteCount) 篇）"
        }

        let report = try importVaultNotes(disk)
        try setIndexDirty(false)
        var line = "已从 vault 重建 \(disk.count) 篇（新增 \(report.inserted)，更新 \(report.updated)，未变 \(report.unchanged)）"
        if !report.titleConflicts.isEmpty {
            line += "，\(report.titleConflicts.count) 篇标题冲突已跳过"
        }
        return line
    }

    /// 本机标识。冲突文件名与同步提交信息要用。
    func deviceId() throws -> String {
        try db.writer.write { conn in
            if let existing = try String.fetchOne(
                conn, sql: "SELECT value FROM meta WHERE key = 'deviceId'"
            ) { return existing }
            let generated = "d" + String(UInt32.random(in: 0..<UInt32.max), radix: 36)
            try conn.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('deviceId', ?)",
                arguments: [generated]
            )
            return generated
        }
    }

    /// 全库导出用的快照。含别名与已忽略的提及 —— 这两样不在正文里，漏了就丢数据。
    func vaultNotes() throws -> [VaultFormat.Note] {
        try db.reader.read { conn in
            let notes = try Note.fetchAll(conn, sql: "SELECT * FROM note ORDER BY id")

            var aliases: [String: [String]] = [:]
            for row in try Row.fetchAll(conn, sql: "SELECT noteId, name FROM alias ORDER BY name") {
                aliases[row["noteId"], default: []].append(row["name"])
            }
            var dismissed: [String: [String]] = [:]
            for row in try Row.fetchAll(
                conn,
                sql: "SELECT noteId, targetId FROM mention WHERE dismissed = 1 ORDER BY targetId"
            ) {
                dismissed[row["noteId"], default: []].append(row["targetId"])
            }

            return notes.map { note in
                VaultFormat.Note(
                    id: note.id,
                    title: note.title,
                    status: note.status,
                    createdAt: note.createdAt,
                    updatedAt: note.updatedAt,
                    aliases: aliases[note.id] ?? [],
                    dismissed: dismissed[note.id] ?? [],
                    body: note.body,
                    type: note.type,
                    meta: note.metaFields,
                    extra: note.frontmatterExtra
                )
            }
        }
    }

    /// 把 vault 里的笔记写回数据库，然后重建索引。
    ///
    /// 冲突只有一个：`titleKey` 有唯一索引，若 A 笔记的标题被另一个 id 占了，
    /// 就跳过这一篇并报告，绝不覆盖。
    @discardableResult
    func importVaultNotes(_ incoming: [VaultFormat.Note]) throws -> VaultImportReport {
        var report = VaultImportReport()
        guard !incoming.isEmpty else { return report }

        var dismissedByNote: [String: [String]] = [:]

        try db.writer.write { conn in
            for item in incoming {
                let titleKey = TextNormalizer.key(item.title)
                let occupiedBy = try String.fetchOne(
                    conn,
                    sql: "SELECT id FROM note WHERE titleKey = ?",
                    arguments: [titleKey]
                )
                if let occupiedBy, occupiedBy != item.id {
                    report.titleConflicts.append(
                        "《\(item.title)》在库里已属于 \(occupiedBy)，与 \(item.id) 冲突，已跳过"
                    )
                    continue
                }

                let existing = try Note.fetchOne(conn, key: item.id)
                if let existing, existing.bodyHash == TextNormalizer.bodyHash(item.body), existing.title == item.title {
                    report.unchanged += 1
                } else if existing == nil {
                    report.inserted += 1
                } else {
                    report.updated += 1
                }

                var note = Note(
                    id: item.id,
                    title: item.title,
                    titleKey: titleKey,
                    body: item.body,
                    status: item.status,
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    bodyHash: TextNormalizer.bodyHash(item.body),
                    type: item.type,
                    meta: "{}",
                    extra: "{}"
                )
                note.setMetaFields(item.meta)
                note.setFrontmatterExtra(item.extra)
                // 创建时间取更早的那个，避免同步把「什么时候写的」改晚。
                if let existing, existing.createdAt < note.createdAt {
                    note.createdAt = existing.createdAt
                }
                try note.save(conn)

                try conn.execute(sql: "DELETE FROM alias WHERE noteId = ?", arguments: [note.id])
                for name in Set(item.aliases) {
                    let key = TextNormalizer.key(name)
                    guard !key.isEmpty, key != titleKey else { continue }
                    try conn.execute(
                        sql: "INSERT OR IGNORE INTO alias (noteId, name, nameKey) VALUES (?, ?, ?)",
                        arguments: [note.id, name, key]
                    )
                }

                try Self.updateFTS(note: note, in: conn)
                dismissedByNote[note.id] = item.dismissed
                report.applied.append(note.id)
            }
        }

        // 引用、提及、标签都是全库性的，一次性重建。
        try rebuildAllIndexes()

        // 提及行刚被重建，此时才能按目标 id 落 dismissed。
        try db.writer.write { conn in
            for (noteId, targets) in dismissedByNote {
                try conn.execute(sql: "UPDATE mention SET dismissed = 0 WHERE noteId = ?", arguments: [noteId])
                for targetId in targets {
                    try conn.execute(
                        sql: "UPDATE mention SET dismissed = 1 WHERE noteId = ? AND targetId = ?",
                        arguments: [noteId, targetId]
                    )
                }
            }
        }

        return report
    }
}
