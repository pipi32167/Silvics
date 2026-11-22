import Foundation
import GRDB

/// 标签、孤儿、Quick Open 这些「列表类」查询。
extension GRDBNoteRepository {

    func allTags() throws -> [TagCount] {
        try db.reader.read { conn in
            try TagIndex.allTags(in: conn)
        }
    }

    /// 带某个标签的笔记。
    func summaries(tagged name: String) throws -> [NoteSummary] {
        let all = try summaries()
        let ids = try db.reader.read { conn in
            Set(try TagIndex.noteIds(tagged: name, in: conn))
        }
        return all.filter { ids.contains($0.id) }
    }

    /// 孤儿笔记：既没有出链，也没有入链。
    func orphans() throws -> [NoteSummary] {
        try summaries().filter { $0.backlinkCount == 0 && $0.outgoingCount == 0 }
    }

    /// `⌘P` Quick Open。
    ///
    /// 排序：前缀命中 → 包含命中 → 标题二元组相似度。
    /// 查询为空时返回最近更新的笔记，当作「最近打开」。
    func quickOpen(query: String, limit: Int = 12) throws -> [QuickOpenItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try summaries()
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
