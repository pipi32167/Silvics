import Foundation
import GRDB

/// 标签索引：从正文扫 `#标签` 写入 `tag` 表。
///
/// 和连接、提及一样，`tag` 只是索引。正文删掉 `#标签` 后再保存，标签就没了。
enum TagIndex {

    /// 重扫一篇笔记的标签。
    static func reindex(note: Note, in db: Database) throws {
        try db.execute(sql: "DELETE FROM tag WHERE noteId = ?", arguments: [note.id])
        guard note.body.contains("#") else { return }
        for hit in TagScanner.scan(note.body) {
            try db.execute(
                sql: "INSERT OR IGNORE INTO tag(noteId, name) VALUES (?, ?)",
                arguments: [note.id, hit.name]
            )
        }
    }

    static func rebuildAll(in db: Database) throws {
        try db.execute(sql: "DELETE FROM tag")
        for note in try Note.fetchAll(db) {
            try reindex(note: note, in: db)
        }
    }

    /// 全部标签与使用次数。按次数降序，次数相同按名字。
    static func allTags(in db: Database) throws -> [TagCount] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT name, COUNT(*) AS n FROM tag GROUP BY name ORDER BY n DESC, name
            """)
        return rows.map { TagCount(name: $0["name"], count: $0["n"]) }
    }

    /// 带某个标签的笔记 id。
    static func noteIds(tagged name: String, in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT t.noteId FROM tag t JOIN note n ON n.id = t.noteId
                WHERE t.name = ? COLLATE NOCASE
                ORDER BY n.updatedAt DESC
                """,
            arguments: [name]
        )
    }
}
