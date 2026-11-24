import Foundation
import GRDB

/// 提及相关的仓库方法。
extension GRDBNoteRepository {

    /// 一篇笔记里的未链接提及。
    func mentions(in noteId: String) throws -> [MentionOccurrence] {
        try db.reader.read { conn in
            try MentionIndex.mentions(noteId: noteId, in: conn)
        }
    }

    /// 全库提及，按目标聚合。
    func mentionGroups() throws -> [MentionGroup] {
        try db.reader.read { conn in
            try MentionIndex.groups(in: conn)
        }
    }

    /// 忽略一条提及。同一目标在本篇里一并忽略，避免反复出现。
    func dismissMention(id: Int64) throws {
        let noteId: String? = try db.writer.write { conn in
            let targetId = try String.fetchOne(
                conn, sql: "SELECT targetId FROM mention WHERE id = ?", arguments: [id]
            )
            guard let targetId else { return nil }
            let noteId = try String.fetchOne(
                conn, sql: "SELECT noteId FROM mention WHERE id = ?", arguments: [id]
            )
            try conn.execute(
                sql: "UPDATE mention SET dismissed = 1 WHERE noteId = ? AND targetId = ?",
                arguments: [noteId, targetId]
            )
            return noteId
        }
        // 忽略项只存库里，必须回写文件。
        if let noteId { try NoteWriter.flush(noteIds: [noteId], repo: self) }
    }

    /// 批量把提及转成引用。整批包在一个事务里。
    ///
    /// - Returns: 每篇受影响笔记的改前 / 改后正文。界面用它做 diff 预览与撤销。
    func convertMentions(occurrenceIds: [Int64]) throws -> [NoteConversion] {
        let conversions = try db.writer.write { conn in
            let conversions = try MentionIndex.convert(occurrenceIds: occurrenceIds, in: conn)
            for conversion in conversions {
                try Self.applyBody(conversion.note, in: conn)
            }
            return conversions
        }
        try NoteWriter.flush(noteIds: conversions.map(\.note.id), repo: self)
        return conversions
    }

    /// 只算不改：给批量面板的 diff 预览用。
    func previewMentionConversion(occurrenceIds: [Int64]) throws -> [NoteConversion] {
        try db.reader.read { conn in
            try MentionIndex.convert(occurrenceIds: occurrenceIds, in: conn)
        }
    }

    /// 撤销一次批量转换：把正文写回改前的内容，并重算索引。
    func restoreBodies(_ bodies: [String: String]) throws {
        let restored: [String] = try db.writer.write { conn in
            var ids: [String] = []
            for (noteId, body) in bodies {
                guard var note = try Note.fetchOne(conn, key: noteId) else { continue }
                guard note.body != body else { continue }
                note.body = body
                try Self.applyBody(note, in: conn)
                ids.append(noteId)
            }
            return ids
        }
        try NoteWriter.flush(noteIds: restored, repo: self)
    }

    /// 全库重扫提及。标题、别名、笔记集合变化后调用。
    func rebuildAllMentions() throws {
        try db.writer.write { conn in
            try MentionIndex.rebuildAll(in: conn)
        }
    }

    /// 写正文并重算该笔记的全部索引。调用方负责事务。
    static func applyBody(_ note: Note, in conn: Database) throws {
        var updated = note
        updated.bodyHash = TextNormalizer.bodyHash(updated.body)
        updated.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try updated.save(conn)
        try Self.reindexAll(note: updated, in: conn)
    }

    /// 改写后重算涉及笔记的正文与索引。调用方负责事务。
    static func applyBodies(_ notes: [Note], in conn: Database) throws {
        for note in notes {
            try applyBody(note, in: conn)
        }
    }
}
