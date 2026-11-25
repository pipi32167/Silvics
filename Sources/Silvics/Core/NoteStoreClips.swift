import Foundation
import GRDB

/// 剪藏的读写。剪藏是 `type = clip` 的普通 note，落 `clips/<id>.md`。
extension GRDBNoteRepository {

    // MARK: - 读

    func clip(id: String) throws -> Note? {
        guard let note = try note(id: id), note.type == NoteTypes.clipID else { return nil }
        return note
    }

    /// 剪藏列表。正文不取，只取列表要显示的字段。
    func clipSummaries(status: ClipStatus? = nil, tagged tag: String? = nil) throws -> [ClipSummary] {
        try db.reader.read { conn in
            var notes = try Note
                .filter(Column("type") == NoteTypes.clipID)
                .order(Column("createdAt").desc)
                .fetchAll(conn)

            if let tag {
                let ids = Set(try TagIndex.noteIds(tagged: tag, in: conn, types: [NoteTypes.clipID]))
                notes = notes.filter { ids.contains($0.id) }
            }
            let list = notes.map(Self.clipSummary)
            guard let status else { return list }
            return list.filter { $0.status == status }
        }
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
