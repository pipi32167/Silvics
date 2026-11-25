import Foundation

/// 剪藏相关的界面状态与动作。独立文件，避免与日记、概念笔记的改动互相踩。
extension AppState {

    // MARK: - 范围

    var isClipScope: Bool { nav.active == .clips }

    /// 当前范围下要显示的剪藏。搜索优先，其次范围。
    var visibleClips: [ClipSummary] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return (try? repo.clipSummaries(query: q)) ?? []
        }
        guard nav.active == .clips else { return [] }
        switch nav.clipScope {
        case .unread: return clipSummaries.filter { $0.status == .unread }
        case .archived: return clipSummaries.filter { $0.status == .archived }
        case .pending: return clipSummaries.filter { $0.aiState != .done }
        case .tag(let name): return clipSummaries.filter { $0.tags.contains(name) }
        case .all: return clipSummaries
        }
    }

    /// 重新载入剪藏列表、计数与标签。切范围、保存、改状态后调用。
    func refreshClips() {
        clipSummaries = (try? repo.clipSummaries()) ?? []
        clipTags = (try? repo.allTags(types: [NoteTypes.clipID])) ?? []
        let counts = (try? repo.clipCounts()) ?? (unread: 0, total: 0, archived: 0)
        clipUnreadCount = counts.unread
        clipTotalCount = counts.total
        clipArchivedCount = counts.archived

        // 标签被删掉后停在空范围会显示空白，退回「全部剪藏」。
        if case .tag(let name) = nav.clipScope, !clipTags.contains(where: { $0.name == name }) {
            setModuleScope(.clip(.all))
        }
    }

    /// 切到剪藏范围。没有选中剪藏时选第一条未读。
    func selectClipScope(_ scope: SidebarScope) {
        flushPendingSave()
        applyLegacyScope(scope)
        searchQuery = ""
        refreshClips()
        // 当前选中的剪藏还在这个范围里就不动它；否则换成范围里的第一条。
        if let current, current.type == NoteTypes.clipID,
           visibleClips.contains(where: { $0.id == current.id }) {
            return
        }
        if let first = visibleClips.first {
            select(first.id)
        } else {
            selection = nil
            current = nil
        }
    }

    // MARK: - 读

    /// 打开剪藏；按设置决定是否自动标已读。
    func openClip(id: String) {
        select(id)
    }

    func clipReferenceCount(id: String) -> Int {
        (try? repo.referenceCount(to: id)) ?? 0
    }

    // MARK: - 写

    func setClipStatus(id: String, status: ClipStatus) {
        do {
            let updated = try repo.updateClipStatus(id: id, status: status)
            if current?.id == updated.id { current = updated }
            refreshClips()
        } catch {
            statusMessage = "改剪藏状态失败：\(error.localizedDescription)"
        }
    }

    func updateClipSummary(id: String, summary: String) {
        do {
            let updated = try repo.updateClipContent(id: id, summary: summary)
            if current?.id == updated.id { current = updated }
            refreshClips()
        } catch {
            statusMessage = "保存摘要失败：\(error.localizedDescription)"
        }
    }

    func updateClipTags(id: String, tags: [String]) {
        do {
            let updated = try repo.updateClipContent(id: id, tags: tags)
            if current?.id == updated.id { current = updated }
            refreshClips()
        } catch {
            statusMessage = "保存标签失败：\(error.localizedDescription)"
        }
    }

    func updateClipBody(id: String, body: String) {
        do {
            let updated = try repo.updateClipBody(id: id, body: body)
            if current?.id == updated.id {
                current = updated
                lastSavedBody = updated.body
            }
            refreshClips()
        } catch {
            statusMessage = "保存正文失败：\(error.localizedDescription)"
        }
    }

    /// 删除剪藏。被引用时返回提示文案，交给界面确认。
    func deleteClip(id: String) {
        let refs = clipReferenceCount(id: id)
        do {
            try repo.delete(id: id)
            // vault 里也要删。导出只写不删，不显式删的话下次同步会把剪藏重新导回来。
            // 用仓库自己的 vault 路径，保证测试注入的临时目录也一致。
            var settings = syncSettings
            settings.vaultPath = repo.vaultURL.path
            try? VaultSync(repo: repo, settings: settings).removeFromVault(id: id)
            if current?.id == id { current = nil }
            if selection == id { selection = nil }
            refreshClips()
            loadAll()
            if let next = visibleClips.first {
                selection = next.id
                loadNote(id: next.id)
            }
            statusMessage = refs > 0 ? "已删除剪藏，\(refs) 篇笔记的引用变成悬空。" : nil
        } catch {
            statusMessage = "删除剪藏失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 设置与模型

    func updateClipSettings(_ settings: ClipSettings) {
        clipSettings = settings.repaired()
        clipSettings.save()
    }

    func resetClipSettings() {
        ClipSettings.clear()
        clipSettings = ClipSettings()
    }

    /// 剪藏整理用的模型。未单独绑定时跟随对话模型。
    func clipProvider() -> (config: ProviderConfig, key: String)? {
        providerService.effective(.clip)
    }

    func clipProviderUnavailableReason() -> String? {
        providerService.unavailableReason(.clip)
    }

    func clipTagCandidates(limit: Int = 80) -> [String] {
        (try? repo.clipTagCandidates(limit: limit)) ?? []
    }

    func clipTitleTaken(_ key: String) -> Bool {
        (try? repo.titleTaken(key, excluding: "")) ?? false
    }

    func existingClip(forURL raw: String) -> ClipSummary? {
        guard let id = try? repo.clipID(forURL: raw) else { return nil }
        return clipSummaries.first { $0.id == id }
    }

    func existingClip(forBody body: String) -> ClipSummary? {
        guard let id = try? repo.clipID(forBodyHash: TextNormalizer.bodyHash(body)) else { return nil }
        return clipSummaries.first { $0.id == id }
    }

    /// 重新整理一篇剪藏的摘要与标签。只改摘要、标签与整理状态，不改标题。
    /// 返回 nil 表示成功；否则是给用户看的原因。
    func retryClipSummary(id: String) async -> String? {
        guard let note = try? repo.clip(id: id) else { return "剪藏不存在" }
        guard let provider = clipProvider() else {
            return clipProviderUnavailableReason() ?? "没有可用的对话模型"
        }
        let settings = clipSettings
        var meta = note.metaFields
        let request = ClipAIRequest(
            sourceTitle: meta[ClipFields.sourceTitle] ?? note.title,
            site: meta[ClipFields.site] ?? "",
            body: note.body,
            existingTags: clipTagCandidates(),
            summaryLimit: settings.summaryLimit,
            tagCount: settings.targetTagCount,
            titleStrategy: .never
        )
        switch await ClipAIService.run(config: provider.config, key: provider.key, request: request) {
        case .failure(let error):
            _ = try? repo.updateClipContent(id: id, aiState: .failed)
            refreshClips()
            return error.message
        case .success(let suggestion):
            let outcome = ClipTagPolicy.apply(
                proposed: suggestion.tags,
                existing: clipTagCandidates(),
                target: settings.targetTagCount
            )
            _ = try? repo.updateClipContent(
                id: id,
                summary: suggestion.summary,
                tags: outcome.tags,
                aiState: .done,
                aiModel: provider.config.chatModel
            )
            if let refreshed = try? repo.clip(id: id) {
                current = refreshed
            }
            refreshClips()
            return nil
        }
    }

    /// 保存新建的剪藏。返回落库后的笔记。
    func saveClip(_ draft: ClipDraft) throws -> Note {
        let note = try repo.createClip(draft)
        refreshClips()
        loadAll()
        selection = note.id
        enterModule(.clips, scope: .clip(.unread))
        loadNote(id: note.id)
        return note
    }
}

// MARK: - 导出

extension AppState {

    /// 导出当前剪藏到一个 `.md`。文件名取标题。
    func exportClip(id: String, to url: URL) throws {
        guard let note = try repo.clip(id: id) else { return }
        let text = ClipExport.markdown(note)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// 导出全部剪藏到一个目录。返回写出的篇数。
    @discardableResult
    func exportAllClips(to directory: URL) throws -> Int {
        let ids = clipSummaries.map(\.id)
        var written = 0
        var used = Set<String>()
        for id in ids {
            guard let note = try repo.clip(id: id) else { continue }
            var name = ClipExport.fileName(for: note)
            var index = 2
            while used.contains(name) {
                name = ClipExport.fileName(for: note, index: index)
                index += 1
            }
            used.insert(name)
            _ = try ClipExport.write(note, to: directory, index: nil)
            written += 1
        }
        return written
    }
}
