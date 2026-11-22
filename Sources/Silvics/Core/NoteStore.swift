import Foundation
import GRDB

/// 笔记仓库。界面只依赖这个协议，P7 换成云端实现时不改界面。
protocol NoteRepository {
    func summaries() throws -> [NoteSummary]
    func note(id: String) throws -> Note?
    func create(title: String) throws -> Note
    func save(_ note: Note) throws -> Note
    func delete(id: String) throws
    func backlinks(to noteId: String) throws -> [Backlink]
    func outgoing(from noteId: String) throws -> [NoteLink]
    func completionItems(query: String, limit: Int) throws -> [CompletionItem]
    func noteExists(titleKey: String) throws -> Bool
    func orphanCount() throws -> Int
    func recentTitles(limit: Int) throws -> [String]

    // 提及（L2）
    func mentions(in noteId: String) throws -> [MentionOccurrence]
    func mentionGroups() throws -> [MentionGroup]
    func dismissMention(id: Int64) throws
    func convertMentions(occurrenceIds: [Int64]) throws -> [NoteConversion]
    /// 只算不改，给 diff 预览用。
    func previewMentionConversion(occurrenceIds: [Int64]) throws -> [NoteConversion]
    func restoreBodies(_ bodies: [String: String]) throws

    // 别名与改名
    func aliases(noteId: String) throws -> [String]
    func addAlias(noteId: String, name: String) throws -> String?
    func removeAlias(noteId: String, name: String) throws -> Bool
    func renameImpact(noteId: String, newTitle: String) throws -> [RenameImpact]
    func rename(noteId: String, newTitle: String) throws -> Int

    // 标签与列表
    func allTags() throws -> [TagCount]
    func summaries(tagged name: String) throws -> [NoteSummary]
    func orphans() throws -> [NoteSummary]
    func quickOpen(query: String, limit: Int) throws -> [QuickOpenItem]
}

/// GRDB 实现。
struct GRDBNoteRepository: NoteRepository {
    let db: AppDatabase

    // MARK: - 读

    func summaries() throws -> [NoteSummary] {
        try db.reader.read { conn in
            let notes = try Note
                .order(Note.Columns.updatedAt.desc)
                .fetchAll(conn)

            // 出边计数
            var outgoing: [String: Int] = [:]
            let outRows = try Row.fetchAll(conn, sql: "SELECT fromId, COUNT(*) AS n FROM link GROUP BY fromId")
            for row in outRows { outgoing[row["fromId"]] = row["n"] }

            // 入边计数
            var incoming: [String: Int] = [:]
            let inRows = try Row.fetchAll(conn, sql: """
                SELECT toId, COUNT(*) AS n FROM link WHERE toId IS NOT NULL GROUP BY toId
                """)
            for row in inRows { incoming[row["toId"]] = row["n"] }

            return notes.map { note in
                NoteSummary(
                    id: note.id,
                    title: note.title,
                    status: note.status,
                    backlinkCount: incoming[note.id] ?? 0,
                    outgoingCount: outgoing[note.id] ?? 0,
                    snippet: Self.snippet(of: note.body),
                    updatedAt: note.updatedAt
                )
            }
        }
    }

    func note(id: String) throws -> Note? {
        try db.reader.read { conn in
            try Note.fetchOne(conn, key: id)
        }
    }

    func orphanCount() throws -> Int {
        try db.reader.read { conn in
            try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM note n
                WHERE NOT EXISTS (SELECT 1 FROM link l WHERE l.toId = n.id)
                  AND NOT EXISTS (SELECT 1 FROM link l WHERE l.fromId = n.id)
                """) ?? 0
        }
    }

    func noteExists(titleKey: String) throws -> Bool {
        try db.reader.read { conn in
            try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE titleKey = ?)", arguments: [titleKey]) ?? false
        }
    }

    func recentTitles(limit: Int) throws -> [String] {
        try db.reader.read { conn in
            try String.fetchAll(conn, sql: "SELECT title FROM note ORDER BY updatedAt DESC LIMIT ?", arguments: [limit])
        }
    }

    /// 反向链接：谁引用了我。带原文上下文片段。
    func backlinks(to noteId: String) throws -> [Backlink] {
        try db.reader.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT l.fromId AS fromId, l.location AS location, l.length AS length,
                       l.status AS status, n.title AS title, n.body AS body
                FROM link l JOIN note n ON n.id = l.fromId
                WHERE l.toId = ?
                ORDER BY n.updatedAt DESC
                """, arguments: [noteId])

            var seen = Set<String>()
            var result: [Backlink] = []
            for row in rows {
                let sourceId: String = row["fromId"]
                guard !seen.contains(sourceId) else { continue }
                seen.insert(sourceId)
                let body: String = row["body"]
                let location: Int = row["location"]
                let length: Int = row["length"]
                result.append(Backlink(
                    sourceId: sourceId,
                    sourceTitle: row["title"],
                    snippet: Self.contextSnippet(in: body, location: location, length: length),
                    isDangling: false
                ))
            }
            return result
        }
    }

    /// 悬空引用：指向的标题还不存在。
    func danglingTargets() throws -> [String] {
        try db.reader.read { conn in
            try String.fetchAll(conn, sql: """
                SELECT DISTINCT rawTarget FROM link WHERE status = 'dangling' ORDER BY rawTarget
                """)
        }
    }

    func outgoing(from noteId: String) throws -> [NoteLink] {
        try db.reader.read { conn in
            try NoteLink
                .filter(NoteLink.Columns.fromId == noteId)
                .order(Column("location"))
                .fetchAll(conn)
        }
    }

    // MARK: - 补全

    func completionItems(query: String, limit: Int = 8) throws -> [CompletionItem] {
        let key = TextNormalizer.key(query)
        return try db.reader.read { conn in
            var items: [CompletionItem] = []

            if !key.isEmpty {
                let notes = try Note.fetchAll(conn, sql: """
                    SELECT * FROM note
                    WHERE titleKey LIKE ? ESCAPE '\\'
                    ORDER BY updatedAt DESC
                    LIMIT 40
                    """, arguments: ["%\(Self.likeEscaped(key))%"])

                // 排序：前缀命中优先，其次被引用次数多。
                let counts = try Self.backlinkCounts(conn)
                let sorted = notes.sorted { a, b in
                    let aPrefix = a.titleKey.hasPrefix(key)
                    let bPrefix = b.titleKey.hasPrefix(key)
                    if aPrefix != bPrefix { return aPrefix }
                    return (counts[a.id] ?? 0) > (counts[b.id] ?? 0)
                }
                items = sorted.prefix(limit).map {
                    CompletionItem(
                        id: $0.id,
                        title: $0.title,
                        status: $0.status,
                        backlinkCount: counts[$0.id] ?? 0,
                        isCreate: false
                    )
                }
            }

            // 已有完全同名的不给「新建」项
            let exactExists = try Bool.fetchOne(
                conn, sql: "SELECT EXISTS(SELECT 1 FROM note WHERE titleKey = ?)", arguments: [key]
            ) ?? false

            if !key.isEmpty && !exactExists {
                items.append(CompletionItem(
                    id: "\u{0}create:\(query)",
                    title: query.trimmingCharacters(in: .whitespacesAndNewlines),
                    status: .seedling,
                    backlinkCount: 0,
                    isCreate: true
                ))
            }
            return items
        }
    }

    private static func backlinkCounts(_ conn: Database) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        let rows = try Row.fetchAll(conn, sql: """
            SELECT toId, COUNT(*) AS n FROM link WHERE toId IS NOT NULL GROUP BY toId
            """)
        for row in rows { counts[row["toId"]] = row["n"] }
        return counts
    }

    // MARK: - 写

    func create(title: String) throws -> Note {
        var note = Note.draft(title: title)
        note = try save(note)
        return note
    }

    /// 保存并重建该笔记的索引（link 表 + FTS）。
    @discardableResult
    func save(_ note: Note) throws -> Note {
        try db.writer.write { conn in
            var updated = note
            updated.titleKey = TextNormalizer.key(updated.title)
            updated.bodyHash = TextNormalizer.bodyHash(updated.body)
            updated.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)

            try updated.save(conn)
            try Self.reindexAll(note: updated, in: conn)
            return updated
        }
    }

    /// `LIKE` 的特殊字符转义。不转义会让 `%` 与 `_` 变成通配符。
    static func likeEscaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// 正文索引全量重算：引用、引用解析、全文索引、提及。
    static func reindexAll(note: Note, in conn: Database) throws {
        try Self.reindex(note: note, in: conn)
        try Self.resolveAllLinks(in: conn)
        try Self.updateFTS(note: note, in: conn)
        let scanner = try MentionIndex.scanner(in: conn)
        try MentionIndex.reindex(note: note, scanner: scanner, in: conn)
        try TagIndex.reindex(note: note, in: conn)
    }

    func delete(id: String) throws {
        try db.writer.write { conn in
            _ = try Note.deleteOne(conn, key: id)
            try conn.execute(sql: "DELETE FROM note_fts WHERE rowid = (SELECT rowid FROM note WHERE id = ?)", arguments: [id])
        }
    }

    // MARK: - 索引

    /// 在当前库内把「标题或别名」映射到笔记 id。引用解析与提及扫描共用。
    static func linkTargets(in db: Database) throws -> [String: String] {
        var idByKey: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, titleKey FROM note") {
            idByKey[row["titleKey"]] = row["id"]
        }
        for row in try Row.fetchAll(db, sql: "SELECT noteId, nameKey FROM alias") {
            idByKey[row["nameKey"]] = row["noteId"]
        }
        return idByKey
    }

    /// 从正文重解析引用边。正文是唯一真相。
    static func reindex(note: Note, in db: Database) throws {
        try db.execute(sql: "DELETE FROM link WHERE fromId = ?", arguments: [note.id])

        let links = WikiScanner.scan(note.body)
        guard !links.isEmpty else { return }

        // 标题键与别名键 → id 查表
        let idByKey = try linkTargets(in: db)

        for link in links {
            let targetKey = TextNormalizer.key(link.target)
            let toId = idByKey[targetKey]
            let nsRange = link.nsRange(in: note.body)
            var row = NoteLink(
                id: nil,
                fromId: note.id,
                toId: toId,
                rawTarget: link.target,
                displayText: link.display ?? link.target,
                anchor: link.anchor,
                location: nsRange.location,
                length: nsRange.length,
                status: toId == nil ? .dangling : .resolved
            )
            try row.insert(db)
        }
    }

    /// 把 link 表的 toId 与 status 按当前标题表重算一遍。
    ///
    /// 必须做的事：先写的 `[[尚未存在的概念]]` 会留成悬空边。
    /// 目标笔记后来建出来时，只有重算才能把边接上。
    /// 标题改名时同理，旧边要退回悬空。
    /// 别名表也要参与解析，否则 `[[别名]]` 在下次全库重算后会被错改成悬空。
    static func resolveAllLinks(in db: Database) throws {
        let idByKey = try linkTargets(in: db)
        for row in try Row.fetchAll(db, sql: "SELECT id, rawTarget, toId, status FROM link") {
            let linkId: Int64 = row["id"]
            let rawTarget: String = row["rawTarget"]
            let existingToId: String? = row["toId"]
            let existingStatus: String = row["status"]

            let resolvedId = idByKey[TextNormalizer.key(rawTarget)]
            let status = resolvedId == nil ? "dangling" : "resolved"

            if existingToId == resolvedId && existingStatus == status { continue }
            try db.execute(
                sql: "UPDATE link SET toId = ?, status = ? WHERE id = ?",
                arguments: [resolvedId, status, linkId]
            )
        }
    }

    /// 全库重建索引。标题改名后调用。
    func rebuildAllIndexes() throws {
        try db.writer.write { conn in
            let notes = try Note.fetchAll(conn)
            try conn.execute(sql: "DELETE FROM link")
            for note in notes {
                try Self.reindex(note: note, in: conn)
            }
            try Self.resolveAllLinks(in: conn)
            try MentionIndex.rebuildAll(in: conn)
            try TagIndex.rebuildAll(in: conn)
        }
    }

    static func updateFTS(note: Note, in db: Database) throws {
        let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM note WHERE id = ?", arguments: [note.id])
        guard let rowid else { return }
        try db.execute(sql: "DELETE FROM note_fts WHERE rowid = ?", arguments: [rowid])
        try db.execute(
            sql: "INSERT INTO note_fts(rowid, title, body) VALUES (?, ?, ?)",
            arguments: [rowid, note.title, note.body]
        )
    }

    // MARK: - 搜索

    func search(_ query: String, limit: Int = 50) throws -> [NoteSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return try summaries() }
        return try db.reader.read { conn in
            // trigram 分词器要求查询串至少 3 个字符；短查询退回 LIKE。
            let rows: [Row]
            if q.count >= 3 {
                rows = try Row.fetchAll(conn, sql: """
                    SELECT n.id AS id, n.title AS title, n.status AS status, n.body AS body,
                           n.updatedAt AS updatedAt
                    FROM note_fts f JOIN note n ON n.rowid = f.rowid
                    WHERE note_fts MATCH ?
                    ORDER BY n.updatedAt DESC LIMIT ?
                    """, arguments: [Self.ftsQuery(q), limit])
            } else {
                rows = try Row.fetchAll(conn, sql: """
                    SELECT id, title, status, body, updatedAt FROM note
                    WHERE title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\'
                    ORDER BY updatedAt DESC LIMIT ?
                    """, arguments: ["%\(Self.likeEscaped(q))%", "%\(Self.likeEscaped(q))%", limit])
            }
            let counts = try Self.backlinkCounts(conn)
            return rows.map { row in
                let id: String = row["id"]
                let body: String = row["body"]
                return NoteSummary(
                    id: id,
                    title: row["title"],
                    status: NoteStatus(rawValue: row["status"]) ?? .seedling,
                    backlinkCount: counts[id] ?? 0,
                    outgoingCount: 0,
                    snippet: q.isEmpty ? Self.snippet(of: body) : Self.snippet(around: q, in: body),
                    updatedAt: row["updatedAt"]
                )
            }
        }
    }

    /// trigram 分词器的 MATCH 串。整体加双引号当短语，避免特殊字符干扰。
    static func ftsQuery(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - 文本工具

    /// 列表用摘要：正文首段，剥掉标记。
    static func snippet(of body: String, limit: Int = 70) -> String {
        cleaned(body, limit: limit)
    }

    /// 搜索摘要：以命中处为中心取一段。
    static func snippet(around query: String, in body: String, limit: Int = 90) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cleaned(body, limit: limit) }
        let ns = body as NSString
        let found = ns.range(of: trimmed, options: [.caseInsensitive])
        guard found.location != NSNotFound else { return cleaned(body, limit: limit) }

        let start = max(0, found.location - 28)
        let end = min(ns.length, NSMaxRange(found) + 46)
        let piece = ns.substring(with: NSRange(location: start, length: end - start))
        var text = cleaned(piece, limit: limit)
        if start > 0 { text = "…" + text }
        if end < ns.length { text += "…" }
        return text
    }

    /// 剥掉 Markdown 标记并压缩空白。
    static func cleaned(_ raw: String, limit: Int) -> String {
        var ns = raw as NSString
        for link in WikiScanner.scan(raw).reversed() {
            let range = NSRange(link.range, in: raw)
            guard range.location + range.length <= ns.length else { continue }
            ns = ns.replacingCharacters(in: range, with: link.display ?? link.target) as NSString
        }
        var text = ns as String

        let patterns = [
            #"(?m)^#{1,6}\s+"#,
            #"(?m)^>\s?"#,
            #"(?m)^[-*+]\s+"#,
            #"(?m)^\d+\.\s+"#,
            #"\*\*([^*]+)\*\*"#,
            #"`([^`]+)`"#,
            #"(?m)^---+$"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = re.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        }

        return text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .prefix(limit)
            .description
    }

    /// 引用命中处的上下文片段。
    static func contextSnippet(in body: String, location: Int, length: Int, radius: Int = 24) -> String {
        let ns = body as NSString
        guard location >= 0, location + length <= ns.length else { return "" }
        let start = max(0, location - radius)
        let end = min(ns.length, location + length + radius)
        var piece = ns.substring(with: NSRange(location: start, length: end - start))
        piece = piece.replacingOccurrences(of: "\n", with: " ")
        piece = piece.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return (start > 0 ? "…" : "") + piece + (end < ns.length ? "…" : "")
    }
}
