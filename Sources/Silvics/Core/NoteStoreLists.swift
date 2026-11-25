import Foundation
import GRDB

/// 标签、孤儿、Quick Open 这些「列表类」查询。
extension GRDBNoteRepository {

    /// 默认范围：主列表类型（概念笔记）。剪藏范围显式传类型。
    func allTags() throws -> [TagCount] { try allTags(types: mainListTypes) }

    /// 默认范围：主列表类型。
    func summaries(tagged name: String) throws -> [NoteSummary] {
        try summaries(tagged: name, types: mainListTypes)
    }

    func allTags(types: [String]) throws -> [TagCount] {
        try db.reader.read { conn in
            try TagIndex.allTags(in: conn, types: types)
        }
    }

    /// 带某个标签的笔记，限定类型范围。
    func summaries(tagged name: String, types: [String]) throws -> [NoteSummary] {
        let all = try summaries().filter { types.contains($0.type) }
        let ids = try db.reader.read { conn in
            Set(try TagIndex.noteIds(tagged: name, in: conn, types: types))
        }
        return all.filter { ids.contains($0.id) }
    }

    /// 孤儿笔记：既没有出链，也没有入链。
    ///
    /// `countsAsOrphan = false` 的类型（日记）不算孤儿：它本来就不该被 `[[ ]]` 指向。
    func orphans() throws -> [NoteSummary] {
        try summaries().filter {
            NoteTypes.descriptor(for: $0.type).countsAsOrphan
                && $0.backlinkCount == 0 && $0.outgoingCount == 0
        }
    }

    /// 侧栏「全部」的条数：只算 `inMainList = true` 的类型。
    func noteCount() throws -> Int {
        try db.reader.read { conn in
            try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(*) FROM note WHERE type IN (\(Self.typePlaceholders(count: mainListTypes.count)))",
                arguments: StatementArguments(mainListTypes)
            ) ?? 0
        }
    }

    /// 侧栏「日记」列表：按日期倒序，带星期与未完成待办条数。
    func journalEntries() throws -> [JournalEntry] {
        let journals: [Note] = try db.reader.read { conn in
            try Note.filter(Column("type") == NoteTypes.journalID).fetchAll(conn)
        }
        return journals
            .compactMap { note -> JournalEntry? in
                guard let date = Self.journalDay(of: note) else { return nil }
                return JournalEntry(
                    id: note.id,
                    date: date,
                    weekday: JournalDate.weekday(date),
                    openTodoCount: JournalTodos.openCount(in: note.body)
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// 待办总览：跨全部日记聚合未完成项，同一条目取最近一天的状态。
    func todoOverview() throws -> [JournalTodo] {
        let journals: [Note] = try db.reader.read { conn in
            try Note.filter(Column("type") == NoteTypes.journalID).fetchAll(conn)
        }
        let pairs = journals.compactMap { note -> (date: String, body: String)? in
            guard let date = Self.journalDay(of: note) else { return nil }
            return (date, note.body)
        }
        return JournalTodos.aggregate(pairs)
    }

    /// 日记日期：优先读类型段，缺了按 id 推。两处都没有就当不是日记，跳过。
    static func journalDay(of note: Note) -> String? {
        if let raw = note.metaFields["date"], (try? JournalDate.normalized(raw)) != nil { return raw }
        return VaultFormat.journalDate(fromID: note.id)
    }

    /// `⌘P` Quick Open。只列 `inQuickOpen == true` 的类型（日记不进）。
    ///
    /// 排序：前缀命中 → 包含命中 → 标题二元组相似度。
    /// 查询为空时返回最近更新的笔记，当作「最近打开」。
    func quickOpen(query: String, limit: Int = 12) throws -> [QuickOpenItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try summaries().filter { NoteTypes.descriptor(for: $0.type).inQuickOpen }
        guard !trimmed.isEmpty else {
            let recent = all.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit)
            return try decorate(Array(recent))
        }

        let key = TextNormalizer.key(trimmed)
        let target = Self.bigrams(key)

        var ranked: [(NoteSummary, Double)] = []
        for note in all {
            let noteKey = TextNormalizer.key(note.title)
            if noteKey == key {
                ranked.append((note, 1000))
                continue
            }
            if noteKey.hasPrefix(key) {
                // 前缀命中按剩余长度惩罚，短的排前面
                ranked.append((note, 900 - Double(noteKey.count - key.count)))
                continue
            }
            if noteKey.contains(key) {
                ranked.append((note, 700 - Double(noteKey.count - key.count)))
                continue
            }
            guard !target.isEmpty else { continue }
            let other = Self.bigrams(noteKey)
            guard !other.isEmpty else { continue }
            let intersection = target.intersection(other).count
            let union = target.union(other).count
            let score = Double(intersection) / Double(max(union, 1))
            if score >= 0.2 {
                ranked.append((note, score * 500))
            }
        }

        let top = ranked
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
        return try decorate(Array(top))
    }

    /// 补上标签。一次查询拿全部，避免 N+1。
    private func decorate(_ summaries: [NoteSummary]) throws -> [QuickOpenItem] {
        guard !summaries.isEmpty else { return [] }
        let tagsByNote = try db.reader.read { conn -> [String: [String]] in
            var map: [String: [String]] = [:]
            for row in try Row.fetchAll(conn, sql: "SELECT noteId, name FROM tag ORDER BY name") {
                map[row["noteId"], default: []].append(row["name"])
            }
            return map
        }
        return summaries.map { summary in
            QuickOpenItem(
                id: summary.id,
                title: summary.title,
                status: summary.status,
                backlinkCount: summary.backlinkCount,
                tags: Array((tagsByNote[summary.id] ?? []).prefix(3))
            )
        }
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count > 1 else { return Set(chars.map(String.init)) }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) {
            out.insert(String(chars[i...(i + 1)]))
        }
        return out
    }
}


// MARK: - 类型范围

extension GRDBNoteRepository {

    /// 「全部」列表包含的类型。描述符是唯一真相，不要在查询里写类型字符串。
    var mainListTypes: [String] {
        NoteTypes.all.values.filter(\.inMainList).map(\.id).sorted()
    }

    /// 生成 SQL 占位符。值仍走绑定参数，不拼字符串。
    static func typePlaceholders(count: Int) -> String {
        Array(repeating: "?", count: max(count, 1)).joined(separator: ", ")
    }
}
