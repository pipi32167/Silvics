import Foundation
import GRDB

/// 提及索引：写入 `mention` 表、查询、批量转换。
///
/// 和 `link` 表一样，`mention` 只是索引。正文变化时全量重扫本篇，
/// 标题或别名变化时全库重扫。任何时候都能从正文重建。
enum MentionIndex {

    // MARK: - 模式集合与缓存

    /// 自动机构建要 10 ms 量级（1000 条标题）。只按「标题集合指纹」重建一次。
    private static let cache = MentionScannerCache()

    /// 全库标题与别名。扫描时再按 `targetId` 排除笔记自身。
    static func patterns(in db: Database) throws -> [MentionPattern] {
        var patterns: [MentionPattern] = []
        for row in try Row.fetchAll(db, sql: "SELECT id, title FROM note") {
            patterns.append(MentionPattern(
                targetId: row["id"],
                displayName: row["title"],
                kind: .exact
            ))
        }
        for row in try Row.fetchAll(db, sql: "SELECT noteId, name FROM alias") {
            patterns.append(MentionPattern(
                targetId: row["noteId"],
                displayName: row["name"],
                kind: .alias
            ))
        }
        return patterns
    }

    /// 取扫描器。标题集合没变时复用上一次的自动机。
    static func scanner(in db: Database) throws -> MentionScanner {
        let patterns = try patterns(in: db)
        var hasher = Hasher()
        for pattern in patterns {
            hasher.combine(pattern.targetId)
            hasher.combine(pattern.displayName)
            hasher.combine(pattern.kind.rawValue)
        }
        let fingerprint = hasher.finalize()
        return cache.scanner(fingerprint: fingerprint) {
            MentionScanner(patterns: patterns)
        }
    }

    // MARK: - 写入

    /// 重扫一篇笔记的提及。`dismissed` 按目标保留。
    static func reindex(note: Note, scanner: MentionScanner, in db: Database) throws {
        let dismissed = Set(try String.fetchAll(
            db,
            sql: "SELECT targetId FROM mention WHERE noteId = ? AND dismissed = 1",
            arguments: [note.id]
        ))
        try db.execute(sql: "DELETE FROM mention WHERE noteId = ?", arguments: [note.id])
        guard !note.body.isEmpty else { return }

        // 排除区：代码块、行内代码、已有引用。
        let spans = MarkdownStyler.analyze(note.body)
        var excluded = spans.codeBlocks + spans.inlineCodes
        excluded.append(contentsOf: WikiScanner.scan(note.body).map { $0.nsRange(in: note.body) })

        for hit in scanner.scan(note.body, excluding: excluded) {
            let pattern = scanner.patterns[hit.patternIndex]
            guard pattern.targetId != note.id else { continue }
            var row = NoteMention(
                id: nil,
                noteId: note.id,
                targetId: pattern.targetId,
                location: hit.range.location,
                length: hit.range.length,
                kind: MentionKind(rawValue: pattern.kind.rawValue) ?? .exact,
                dismissed: dismissed.contains(pattern.targetId)
            )
            try row.insert(db)
        }
    }

    /// 全库重扫提及。标题或别名变化后调用。
    ///
    /// `dismissed` 必须跨重建保留：它是用户的决定，正文里没有，重建一次就丢是数据损失。
    static func rebuildAll(in db: Database) throws {
        let dismissedPairs = try Row.fetchAll(
            db, sql: "SELECT noteId, targetId FROM mention WHERE dismissed = 1"
        ).map { (noteId: $0["noteId"] as String, targetId: $0["targetId"] as String) }
        let scanner = try scanner(in: db)
        try db.execute(sql: "DELETE FROM mention")
        let notes = try Note.fetchAll(db)
        for note in notes {
            try reindex(note: note, scanner: scanner, in: db)
        }
        for pair in dismissedPairs {
            try db.execute(
                sql: "UPDATE mention SET dismissed = 1 WHERE noteId = ? AND targetId = ?",
                arguments: [pair.noteId, pair.targetId]
            )
        }
    }

    // MARK: - 查询

    /// 一篇笔记里的提及，按位置排序。
    static func mentions(noteId: String, in db: Database) throws -> [MentionOccurrence] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.id AS id, m.noteId AS noteId, m.targetId AS targetId,
                   m.location AS location, m.length AS length, m.kind AS kind,
                   t.title AS targetTitle, n.title AS noteTitle, n.body AS body
            FROM mention m
            JOIN note t ON t.id = m.targetId
            JOIN note n ON n.id = m.noteId
            WHERE m.noteId = ? AND m.dismissed = 0
            ORDER BY m.location
            """, arguments: [noteId])
        return try rows.map { try Self.occurrence(from: $0) }
    }

    /// 全库提及，按目标聚合。给批量面板用。
    static func groups(in db: Database) throws -> [MentionGroup] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.id AS id, m.noteId AS noteId, m.targetId AS targetId,
                   m.location AS location, m.length AS length, m.kind AS kind,
                   t.title AS targetTitle, n.title AS noteTitle, n.body AS body
            FROM mention m
            JOIN note t ON t.id = m.targetId
            JOIN note n ON n.id = m.noteId
            WHERE m.dismissed = 0
            ORDER BY t.title, n.updatedAt DESC, m.location
            """)

        var order: [String] = []
        var buckets: [String: [MentionOccurrence]] = [:]
        var titles: [String: String] = [:]
        for row in rows {
            let occurrence = try Self.occurrence(from: row)
            let targetId: String = row["targetId"]
            if buckets[targetId] == nil {
                buckets[targetId] = []
                order.append(targetId)
                titles[targetId] = row["targetTitle"]
            }
            buckets[targetId]?.append(occurrence)
        }

        return order.compactMap { targetId in
            guard let occurrences = buckets[targetId], let title = titles[targetId] else { return nil }
            return MentionGroup(
                targetId: targetId,
                targetTitle: title,
                occurrences: occurrences,
                noteCount: Set(occurrences.map(\.noteId)).count
            )
        }
    }

    private static func occurrence(from row: Row) throws -> MentionOccurrence {
        let body: String = row["body"]
        let location: Int = row["location"]
        let length: Int = row["length"]
        return MentionOccurrence(
            id: row["id"],
            noteId: row["noteId"],
            noteTitle: row["noteTitle"],
            targetId: row["targetId"],
            targetTitle: row["targetTitle"],
            location: location,
            length: length,
            kind: MentionKind(rawValue: row["kind"]) ?? .exact,
            snippet: GRDBNoteRepository.contextSnippet(in: body, location: location, length: length)
        )
    }

    // MARK: - 改写

    /// 把选中的提及转成 `[[引用]]`。
    ///
    /// - Returns: 每篇受影响笔记的改前 / 改后正文，供预览与撤销。
    ///
    /// 只改正文，索引随后重算。调用方负责包事务。
    static func convert(
        occurrenceIds: [Int64],
        in db: Database
    ) throws -> [NoteConversion] {
        guard !occurrenceIds.isEmpty else { return [] }

        let placeholders = occurrenceIds.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.id AS id, m.noteId AS noteId, m.location AS location, m.length AS length,
                   t.title AS targetTitle
            FROM mention m JOIN note t ON t.id = m.targetId
            WHERE m.id IN (\(placeholders))
            """, arguments: StatementArguments(occurrenceIds))

        struct Edit { var location: Int; var length: Int; var title: String }
        var editsByNote: [String: [Edit]] = [:]
        for row in rows {
            let noteId: String = row["noteId"]
            editsByNote[noteId, default: []].append(Edit(
                location: row["location"], length: row["length"], title: row["targetTitle"]
            ))
        }

        var conversions: [NoteConversion] = []
        for (noteId, edits) in editsByNote.sorted(by: { $0.key < $1.key }) {
            guard let note = try Note.fetchOne(db, key: noteId) else { continue }
            let ns = NSMutableString(string: note.body)
            var applied = 0
            for edit in edits.sorted(by: { $0.location > $1.location }) {
                let range = NSRange(location: edit.location, length: edit.length)
                guard range.location >= 0, NSMaxRange(range) <= ns.length else { continue }
                ns.replaceCharacters(in: range, with: "[[\(edit.title)]]")
                applied += 1
            }
            guard applied > 0 else { continue }
            var updated = note
            updated.body = ns as String
            conversions.append(NoteConversion(
                note: updated,
                previousBody: note.body,
                insertedCount: applied
            ))
        }
        return conversions
    }
}

// MARK: - 自动机缓存

/// 线程安全的单槽缓存。指纹变了就重建。
final class MentionScannerCache: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprint: Int?
    private var cached: MentionScanner?

    func scanner(fingerprint newFingerprint: Int, build: () -> MentionScanner) -> MentionScanner {
        lock.lock()
        defer { lock.unlock() }
        if let cached, fingerprint == newFingerprint { return cached }
        let built = build()
        cached = built
        fingerprint = newFingerprint
        return built
    }
}
