import Foundation
import GRDB

/// 别名与改名的仓库方法。
extension GRDBNoteRepository {

    // MARK: - 别名

    func aliases(noteId: String) throws -> [String] {
        try db.reader.read { conn in
            try String.fetchAll(
                conn,
                sql: "SELECT name FROM alias WHERE noteId = ? ORDER BY name",
                arguments: [noteId]
            )
        }
    }

    /// 加别名。重名、与已有标题冲突、与自己的标题相同时返回错误说明。
    @discardableResult
    func addAlias(noteId: String, name: String) throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = TextNormalizer.key(trimmed)
        guard !key.isEmpty else { return "别名不能为空" }
        if let message = TextNormalizer.validateTitle(trimmed) { return message }

        let message: String? = try db.writer.write { conn in
            if let ownTitle = try String.fetchOne(
                conn, sql: "SELECT titleKey FROM note WHERE id = ?", arguments: [noteId]
            ), ownTitle == key {
                return "别名不能和笔记自己的标题相同"
            }
            if try Bool.fetchOne(
                conn, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE titleKey = ? AND id <> ?)",
                arguments: [key, noteId]
            ) ?? false {
                return "已有同名笔记，别名会与它冲突"
            }
            if try Bool.fetchOne(
                conn, sql: "SELECT EXISTS(SELECT 1 FROM alias WHERE nameKey = ? AND noteId <> ?)",
                arguments: [key, noteId]
            ) ?? false {
                return "这个别名已被别的笔记占用"
            }
            try conn.execute(
                sql: "INSERT OR IGNORE INTO alias(noteId, name, nameKey) VALUES (?, ?, ?)",
                arguments: [noteId, trimmed, key]
            )
            try MentionIndex.rebuildAll(in: conn, journalScanMentions: journalScanMentions)
            return nil
        }
        // 别名只存在库里，必须写回文件，否则删库重建就丢。
        if message == nil { try NoteWriter.flush(noteIds: [noteId], repo: self) }
        return message
    }

    @discardableResult
    func removeAlias(noteId: String, name: String) throws -> Bool {
        let key = TextNormalizer.key(name)
        let deleted = try db.writer.write { conn in
            try conn.execute(
                sql: "DELETE FROM alias WHERE noteId = ? AND nameKey = ?",
                arguments: [noteId, key]
            )
            let deleted = conn.changesCount > 0
            try MentionIndex.rebuildAll(in: conn, journalScanMentions: journalScanMentions)
            return deleted
        }
        if deleted { try NoteWriter.flush(noteIds: [noteId], repo: self) }
        return deleted
    }

    // MARK: - 改名

    /// 改名会影响哪些笔记的正文。先给用户看，再动手。
    func renameImpact(noteId: String, newTitle: String) throws -> [RenameImpact] {
        let newKey = TextNormalizer.key(newTitle)
        return try db.reader.read { conn in
            let oldTitle = try String.fetchOne(
                conn, sql: "SELECT title FROM note WHERE id = ?", arguments: [noteId]
            )
            let oldKey = TextNormalizer.key(oldTitle ?? "")
            guard oldKey != newKey else { return [] }

            var impacts: [RenameImpact] = []
            for row in try Row.fetchAll(conn, sql: "SELECT id, title, body FROM note") {
                let body: String = row["body"]
                let count = WikiScanner.scan(body).filter {
                    TextNormalizer.key($0.target) == oldKey
                }.count
                guard count > 0 else { continue }
                impacts.append(RenameImpact(
                    noteId: row["id"], noteTitle: row["title"], occurrences: count
                ))
            }
            return impacts.sorted { $0.occurrences > $1.occurrences }
        }
    }

    /// 改名：改标题、把旧标题收进别名、把全库正文里的旧引用改写成新标题。
    ///
    /// - Returns: 被改写的正文篇数（不含只改标题的那一篇）。
    @discardableResult
    func rename(noteId: String, newTitle: String) throws -> Int {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKey = TextNormalizer.key(trimmed)
        // 概念笔记套断言校验；剪藏与日记不套（文章标题、日期都不是断言）。
        let targetType = (try? note(id: noteId))??.type ?? NoteTypes.noteID
        if NoteTypes.descriptor(for: targetType).validatesTitle,
           let message = TextNormalizer.validateTitle(trimmed) {
            throw RenameError.invalidTitle(message)
        }

        let changed = try db.writer.write { conn -> [String] in
            guard var note = try Note.fetchOne(conn, key: noteId) else { return [] }
            let oldTitle = note.title
            let oldKey = TextNormalizer.key(oldTitle)
            guard oldKey != newKey else { return [] }
            return try Self.performRename(
                note: &note, oldKey: oldKey, oldTitle: oldTitle, newTitle: trimmed,
                journalScanMentions: journalScanMentions, in: conn
            )
        }
        // 改名改了标题与正文，文件要跟着写，否则删库重建会退回旧标题。
        try NoteWriter.flush(noteIds: changed, repo: self)
        return changed.filter { $0 != noteId }.count
    }

    private static func performRename(
        note: inout Note,
        oldKey: String,
        oldTitle: String,
        newTitle: String,
        journalScanMentions: Bool,
        in conn: Database
    ) throws -> [String] {
        // 1. 全库改写 `[[旧标题]]`、`[[旧标题|x]]`、`[[旧标题#a]]`。
        // 只改会解析 `[[ ]]` 的类型。剪藏原文里的字面 `[[ ]]` 不是引用，不能动。
        var rewritten: [Note] = []
        for var candidate in try Note.fetchAll(conn) where candidate.noteType.emitsLinks {
            let replacements = WikiScanner.scan(candidate.body).filter {
                TextNormalizer.key($0.target) == oldKey
            }
            guard !replacements.isEmpty else { continue }
            candidate.body = Self.rewrite(body: candidate.body, links: replacements, newTitle: newTitle)
            rewritten.append(candidate)
        }

        // 2. 改标题。
        note.title = newTitle
        note.titleKey = TextNormalizer.key(newTitle)
        note.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try note.save(conn)

        // 3. 旧标题进别名，避免外部链接立刻变悬空。
        let conflict = try Bool.fetchOne(
            conn,
            sql: "SELECT EXISTS(SELECT 1 FROM note WHERE titleKey = ?) OR EXISTS(SELECT 1 FROM alias WHERE nameKey = ?)",
            arguments: [oldKey, oldKey]
        ) ?? false
        if !conflict {
            try conn.execute(
                sql: "INSERT OR IGNORE INTO alias(noteId, name, nameKey) VALUES (?, ?, ?)",
                arguments: [note.id, oldTitle, oldKey]
            )
        }

        // 4. 重算所有被改写正文的索引，再全库重解析引用。
        try applyBodies(rewritten, in: conn, journalScanMentions: journalScanMentions)
        try resolveAllLinks(in: conn)
        try MentionIndex.rebuildAll(in: conn, journalScanMentions: journalScanMentions)

        // 被改写的正文也要回写文件。改过标题的那篇排在前面。
        return [note.id] + rewritten.map(\.id)
    }

    /// 把命中的引用整段改写成新标题，保留显示名与锚点。
    static func rewrite(body: String, links: [WikiLink], newTitle: String) -> String {
        let ns = NSMutableString(string: body)
        for link in links.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let range = NSRange(link.range, in: body)
            guard NSMaxRange(range) <= ns.length else { continue }
            var replacement = "[[\(newTitle)"
            if let anchor = link.anchor { replacement += "#\(anchor)" }
            if let display = link.display { replacement += "|\(display)" }
            replacement += "]]"
            ns.replaceCharacters(in: range, with: replacement)
        }
        return ns as String
    }
}

enum RenameError: LocalizedError {
    case invalidTitle(String)

    var errorDescription: String? {
        switch self {
        case .invalidTitle(let message): return message
        }
    }
}
