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
                    body: note.body
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
                    bodyHash: TextNormalizer.bodyHash(item.body)
                )
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
