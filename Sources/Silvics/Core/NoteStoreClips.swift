import Foundation
import GRDB

/// 剪藏的读写。剪藏是 `type = clip` 的普通 note，落 `clips/<id>.md`。
extension GRDBNoteRepository {

    // MARK: - 读

    func clip(id: String) throws -> Note? {
        guard let note = try note(id: id), note.type == NoteTypes.clipID else { return nil }
        return note
    }

    /// 剪藏列表。只取列表要显示的列，不碰正文。
    ///
    /// 单篇正文常有几十 KB。取整行 `Note` 会把所有正文解码一遍，
    /// 每次切模块白读几 MB（issue #42：120 篇实测 57 ms）。
    func clipSummaries(status: ClipStatus? = nil, tagged tag: String? = nil) throws -> [ClipSummary] {
        try db.reader.read { conn in
            var list = try Self.clipSummaries(in: conn, tagged: tag)
            guard let status else { return list }
            list = list.filter { $0.status == status }
            return list
        }
    }

    /// 列表用的列。与 `clipSummary(_ note:)` 一一对应，改字段时两处一起改。
    static let clipSummaryColumns =
        "id, title, tags, meta, createdAt, length(body) AS bodyLength"

    private static func clipSummaries(in conn: Database, tagged tag: String?) throws -> [ClipSummary] {
        let rows = try Row.fetchAll(conn, sql: """
            SELECT \(clipSummaryColumns)
            FROM note
            WHERE type = ?
            ORDER BY createdAt DESC
            """, arguments: [NoteTypes.clipID])

        var list = rows.map(Self.clipSummary)
        if let tag {
            let ids = Set(try TagIndex.noteIds(tagged: tag, in: conn, types: [NoteTypes.clipID]))
            list = list.filter { ids.contains($0.id) }
        }
        return list
    }

    func clipUnreadCount() throws -> Int {
        try db.reader.read { conn in
            try Int.fetchOne(
                conn,
                sql: """
                    SELECT COUNT(*) FROM note
                    WHERE type = ? AND json_extract(meta, '$.clipStatus') = ?
                    """,
                arguments: [NoteTypes.clipID, ClipStatus.unread.rawValue]
            ) ?? 0
        }
    }

    /// 同一个地址是否已经剪藏过。地址先归一化。
    func clipID(forURL raw: String) throws -> String? {
        guard let normalized = ClipURL.normalized(raw) else { return nil }
        return try db.reader.read { conn in
            try String.fetchOne(
                conn,
                sql: """
                    SELECT id FROM note
                    WHERE type = ? AND json_extract(meta, '$.url') = ?
                    LIMIT 1
                    """,
                arguments: [NoteTypes.clipID, normalized]
            )
        }
    }

    /// 正文相同（粘贴与文件导入用）。只提示，不拦截。
    func clipID(forBodyHash hash: String) throws -> String? {
        try db.reader.read { conn in
            try String.fetchOne(
                conn,
                sql: "SELECT id FROM note WHERE type = ? AND bodyHash = ? LIMIT 1",
                arguments: [NoteTypes.clipID, hash]
            )
        }
    }

    /// 被别的笔记引用的次数。删除前提示用。
    func referenceCount(to noteId: String) throws -> Int {
        try db.reader.read { conn in
            try Int.fetchOne(
                conn,
                sql: "SELECT COUNT(DISTINCT fromId) FROM link WHERE toId = ?",
                arguments: [noteId]
            ) ?? 0
        }
    }

    // MARK: - 写

    /// 新建剪藏。
    ///
    /// 标题走 `ClipTitle.finalize`：清洗、兜底、日期式标题追加来源、重名追加来源或序号。
    /// 地址重复直接拦下；正文相同只由调用方提示，不在这里拦。
    @discardableResult
    func createClip(_ draft: ClipDraft) throws -> Note {
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ClipError.emptyBody }

        let normalizedURL: String
        if draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedURL = ""
        } else {
            guard let value = ClipURL.normalized(draft.url) else {
                throw ClipError.invalidURL(draft.url)
            }
            normalizedURL = value
            if let existing = try clipID(forURL: normalizedURL),
               let note = try note(id: existing) {
                throw ClipError.duplicateURL(noteId: note.id, title: note.title)
            }
        }

        let title = ClipTitle.finalize(
            raw: draft.title.isEmpty ? draft.sourceTitle : draft.title,
            source: draft.site,
            body: body,
            isTaken: { [repo = self] key in (try? repo.titleTaken(key, excluding: "")) ?? false }
        )

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var note = Note(
            id: Note.makeId(),
            title: title,
            titleKey: TextNormalizer.key(title),
            body: body,
            status: .seedling,
            createdAt: now,
            updatedAt: now,
            bodyHash: TextNormalizer.bodyHash(body),
            type: NoteTypes.clipID,
            meta: "{}",
            extra: "{}",
            tags: "[]"
        )
        note.setMetaFields(Self.clipMeta(
            url: normalizedURL,
            site: draft.site,
            author: draft.author,
            published: draft.published,
            sourceTitle: draft.sourceTitle.isEmpty ? title : draft.sourceTitle,
            summary: draft.summary,
            status: draft.status,
            aiState: draft.aiState,
            aiModel: draft.aiModel
        ))
        note.setTagNames(draft.tags)
        return try save(note)
    }

    /// 改阅读状态。正文不动，只改类型段。
    @discardableResult
    func updateClipStatus(id: String, status: ClipStatus) throws -> Note {
        try mutateClip(id: id) { meta in
            meta[ClipFields.status] = status.rawValue
        }
    }

    /// 改摘要、标签与整理状态。
    @discardableResult
    func updateClipContent(
        id: String,
        summary: String? = nil,
        tags: [String]? = nil,
        aiState: ClipAIState? = nil,
        aiModel: String? = nil
    ) throws -> Note {
        try mutateClip(id: id) { meta in
            if let summary { meta[ClipFields.summary] = summary }
            if let aiState { meta[ClipFields.aiState] = aiState.rawValue }
            if let aiModel { meta[ClipFields.aiModel] = aiModel }
        } tags: { note in
            if let tags { note.setTagNames(tags) }
        }
    }

    /// 编辑正文（「编辑正文」开关）。剪藏正文不会解析 `[[ ]]`。
    @discardableResult
    func updateClipBody(id: String, body: String) throws -> Note {
        try mutateClip(id: id, meta: { _ in }) { note in
            note.body = body
            note.bodyHash = TextNormalizer.bodyHash(body)
        }
    }

    // MARK: - 内部

    private func mutateClip(
        id: String,
        meta: (inout [String: String]) -> Void,
        tags: (inout Note) -> Void = { _ in }
    ) throws -> Note {
        guard var note = try clip(id: id) else {
            throw ClipError.emptyBody
        }
        var fields = note.metaFields
        meta(&fields)
        note.setMetaFields(fields)
        tags(&note)
        return try save(note)
    }

    static func clipMeta(
        url: String,
        site: String,
        author: String,
        published: String,
        sourceTitle: String,
        summary: String,
        status: ClipStatus,
        aiState: ClipAIState,
        aiModel: String
    ) -> [String: String] {
        var meta: [String: String] = [
            ClipFields.status: status.rawValue,
            ClipFields.aiState: aiState.rawValue,
        ]
        if !url.isEmpty { meta[ClipFields.url] = url }
        if !site.isEmpty { meta[ClipFields.site] = site }
        if !author.isEmpty { meta[ClipFields.author] = author }
        if !published.isEmpty { meta[ClipFields.published] = published }
        if !sourceTitle.isEmpty { meta[ClipFields.sourceTitle] = sourceTitle }
        if !summary.isEmpty { meta[ClipFields.summary] = summary }
        if !aiModel.isEmpty { meta[ClipFields.aiModel] = aiModel }
        return meta
    }

    /// 行 → 列表模型。字段必须与 `clipSummaryColumns` 对齐。
    static func clipSummary(_ row: Row) -> ClipSummary {
        let meta = metaFields(row["meta"])
        let status = ClipStatus(rawValue: meta[ClipFields.status] ?? "") ?? .unread
        let aiState = ClipAIState(rawValue: meta[ClipFields.aiState] ?? "") ?? .pending
        return ClipSummary(
            id: row["id"],
            title: row["title"],
            site: meta[ClipFields.site] ?? "",
            url: meta[ClipFields.url] ?? "",
            summary: meta[ClipFields.summary] ?? "",
            status: status,
            aiState: aiState,
            tags: tagNames(row["tags"]),
            createdAt: row["createdAt"],
            charCount: row["bodyLength"] ?? 0
        )
    }

    /// `meta` 列的 JSON 解析。解析失败按空字典处理，与 `Note.metaFields` 一致。
    private static func metaFields(_ raw: String) -> [String: String] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func tagNames(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    static func clipSummary(_ note: Note) -> ClipSummary {
        let meta = note.metaFields
        let status = ClipStatus(rawValue: meta[ClipFields.status] ?? "") ?? .unread
        let aiState = ClipAIState(rawValue: meta[ClipFields.aiState] ?? "") ?? .pending
        return ClipSummary(
            id: note.id,
            title: note.title,
            site: meta[ClipFields.site] ?? "",
            url: meta[ClipFields.url] ?? "",
            summary: meta[ClipFields.summary] ?? "",
            status: status,
            aiState: aiState,
            tags: note.tagNames,
            createdAt: note.createdAt,
            charCount: note.body.count
        )
    }
}

// MARK: - 标签候选

extension GRDBNoteRepository {

    /// 标签候选：剪藏标签 ∪ 概念笔记标签，按使用次数降序。
    ///
    /// 只做建议：模型从这里挑，或用新标签。数量上限由调用方控制。
    func clipTagCandidates(limit: Int = 80) throws -> [String] {
        let clipTags = try allTags(types: [NoteTypes.clipID])
        let noteTags = try allTags(types: [NoteTypes.noteID])
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for tag in clipTags + noteTags {
            let key = ClipTagPolicy.key(tag.name)
            counts[key, default: 0] += tag.count
            if spelling[key] == nil { spelling[key] = tag.name }
        }
        return counts.keys
            .sorted { lhs, rhs in
                if counts[lhs] != counts[rhs] { return (counts[lhs] ?? 0) > (counts[rhs] ?? 0) }
                return lhs < rhs
            }
            .prefix(limit)
            .compactMap { spelling[$0] }
    }
}

// MARK: - 搜索

extension GRDBNoteRepository {

    /// 剪藏范围内搜索：标题、摘要、正文、标签。
    ///
    /// 摘要与标签已写进 FTS（见 `updateFTS`），这里只用 FTS + LIKE 兜底短查询。
    /// 只取列表列，与 `clipSummaries()` 同一套字段（issue #42）。
    func clipSummaries(query: String, status: ClipStatus? = nil) throws -> [ClipSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return try clipSummaries(status: status) }

        let lightColumns = """
            n.id, n.title, n.tags, n.meta, n.createdAt, length(n.body) AS bodyLength
            """
        let rows: [Row] = try db.reader.read { conn in
            if q.count >= 3 {
                return try Row.fetchAll(conn, sql: """
                    SELECT \(lightColumns) FROM note_fts f JOIN note n ON n.rowid = f.rowid
                    WHERE note_fts MATCH ? AND n.type = ?
                    ORDER BY n.createdAt DESC LIMIT 100
                    """, arguments: [Self.ftsQuery(q), NoteTypes.clipID])
            }
            return try Row.fetchAll(conn, sql: """
                SELECT \(lightColumns) FROM note n
                WHERE n.type = ?
                  AND (n.title LIKE ? ESCAPE '\\' OR n.body LIKE ? ESCAPE '\\')
                ORDER BY n.createdAt DESC LIMIT 100
                """, arguments: [NoteTypes.clipID, "%\(Self.likeEscaped(q))%", "%\(Self.likeEscaped(q))%"])
        }

        var list = rows.map(Self.clipSummary)
        guard let status else { return list }
        list = list.filter { $0.status == status }
        return list
    }

    /// 剪藏各状态计数。侧栏与设置页用。
    ///
    /// 走 SQL 计数，不重读列表（issue #42：之前内部再调一次 `clipSummaries()`，57 ms × 2）。
    func clipCounts() throws -> (unread: Int, total: Int, archived: Int) {
        try db.reader.read { conn in
            func count(_ status: ClipStatus?) throws -> Int {
                guard let status else {
                    return try Int.fetchOne(
                        conn,
                        sql: "SELECT COUNT(*) FROM note WHERE type = ?",
                        arguments: [NoteTypes.clipID]
                    ) ?? 0
                }
                return try Int.fetchOne(
                    conn,
                    sql: """
                        SELECT COUNT(*) FROM note
                        WHERE type = ? AND json_extract(meta, '$.clipStatus') = ?
                        """,
                    arguments: [NoteTypes.clipID, status.rawValue]
                ) ?? 0
            }
            return (unread: try count(.unread), total: try count(nil), archived: try count(.archived))
        }
    }
}
