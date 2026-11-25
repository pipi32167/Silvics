import Foundation
import GRDB

/// 标签索引：写入 `tag` 表，供筛选与计数。
///
/// 两种来源：
/// - 正文标签（概念笔记、日记）：从正文扫 `#标签`。
/// - 元数据标签（剪藏）：读 `note.tags`，AI 生成，不写进正文。
///
/// `tag` 始终是索引。正文或 `note.tags` 变了就重扫本篇。
enum TagIndex {

    /// 重扫一篇笔记的标签。
    static func reindex(note: Note, in db: Database) throws {
        try db.execute(sql: "DELETE FROM tag WHERE noteId = ?", arguments: [note.id])

        let names: [String]
        if note.noteType.tagsInBody {
            guard note.body.contains("#") else { return }
            names = TagScanner.scan(note.body).map(\.name)
        } else {
            names = note.tagNames
        }
        for name in names {
            try db.execute(
                sql: "INSERT OR IGNORE INTO tag(noteId, name) VALUES (?, ?)",
                arguments: [note.id, name]
            )
        }
    }

    static func rebuildAll(in db: Database) throws {
        try db.execute(sql: "DELETE FROM tag")
        for note in try Note.fetchAll(db) {
            try reindex(note: note, in: db)
        }
    }

    /// 某个范围内的全部标签与使用次数。按次数降序，次数相同按名字。
    ///
    /// 范围由调用方给类型列表。概念侧栏只传概念类型，剪藏范围只传剪藏。
    static func allTags(in db: Database, types: [String]) throws -> [TagCount] {
        guard !types.isEmpty else { return [] }
        let placeholders = types.map { _ in "?" }.joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.name AS name, COUNT(*) AS n
            FROM tag t JOIN note n ON n.id = t.noteId
            WHERE n.type IN (\(placeholders))
            GROUP BY t.name
            ORDER BY n DESC, t.name
            """, arguments: StatementArguments(types))
        return rows.map { TagCount(name: $0["name"], count: $0["n"]) }
    }

    /// 带某个标签的笔记 id，限定类型范围。
    static func noteIds(tagged name: String, in db: Database, types: [String]) throws -> [String] {
        guard !types.isEmpty else { return [] }
        let placeholders = types.map { _ in "?" }.joined(separator: ", ")
        var arguments: [any DatabaseValueConvertible] = [name]
        arguments.append(contentsOf: types)
        return try String.fetchAll(
            db,
            sql: """
                SELECT t.noteId FROM tag t JOIN note n ON n.id = t.noteId
                WHERE t.name = ? COLLATE NOCASE
                  AND n.type IN (\(placeholders))
                ORDER BY n.updatedAt DESC
                """,
            arguments: StatementArguments(arguments)
        )
    }
}
