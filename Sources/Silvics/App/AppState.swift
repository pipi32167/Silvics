import Foundation
import SwiftUI

/// 单一状态源。界面只与它对话。
@MainActor
final class AppState: ObservableObject {

    // MARK: - 发布状态

    @Published private(set) var summaries: [NoteSummary] = []
    @Published var selection: String?          // 选中的笔记 id
    @Published private(set) var current: Note?
    @Published private(set) var backlinks: [Backlink] = []
    @Published private(set) var outgoing: [NoteLink] = []
    @Published private(set) var danglingTargets: [String] = []
    @Published private(set) var orphanCount: Int = 0
    @Published var searchQuery: String = ""
    /// 侧栏当前范围：全部 / 孤儿 / 某个标签。
    @Published var sidebarScope: SidebarScope = .all
    /// 外观设置。改动即时生效并落 UserDefaults。
    @Published private(set) var appearance: AppearanceSettings = .init()
    /// 模型服务设置。密钥在 Keychain，这里只有非敏感部分。
    @Published private(set) var providerSettings = ProviderSettings()
    /// 哪些 provider 已经存了密钥。列表里显示「已配置」用。
    @Published private(set) var providersWithKey: Set<UUID> = []
    /// 最近一次同步里没能自动合并的正文冲突。
    @Published private(set) var syncConflicts: [VaultConflict] = []
    @Published var isShowingConflicts: Bool = false
    /// 同步状态一行字：已同步 15:02 / 同步失败：…
    @Published private(set) var syncStatusLine: String = ""
    /// 全部标签与使用次数。
    @Published private(set) var tags: [TagCount] = []
    @Published var isShowingQuickOpen: Bool = false
    @Published private(set) var statusMessage: String?
    @Published var isShowingNewNote: Bool = false
    @Published var isShowingMentionsSheet: Bool = false
    @Published var isShowingAliasSheet: Bool = false
    @Published var isShowingRenameSheet: Bool = false
    /// 当前笔记的未链接提及（L2）。
    @Published private(set) var mentions: [MentionOccurrence] = []
    /// 全库提及，按目标聚合。批量面板用。
    @Published private(set) var mentionGroups: [MentionGroup] = []
    /// 当前笔记的别名。
    @Published private(set) var aliases: [String] = []
    @Published private(set) var isCompletionVisible: Bool = false
    /// 上次批量转换的撤销信息。`nil` 表示没有可撤销的转换。
    @Published private(set) var lastConversionSummary: String?
    /// 已解析的标题键集合。驱动引用是实线还是虚线。
    @Published private(set) var resolvedKeys: Set<String> = []

    // MARK: - 备份与同步

    @Published private(set) var syncSettings: SyncSettings = .load()
    @Published private(set) var isSyncing: Bool = false

    // MARK: - 内部

    private let repo: GRDBNoteRepository
    private let database: AppDatabase
    /// 模型服务的读写与校验。密钥走 Keychain。
    let providerService = ProviderService()
    private var saveTask: Task<Void, Never>?
    /// 最近一次落库的正文，用于跳过无变化的保存。
    private var lastSavedBody: String = ""
    /// 上次批量转换前的正文。按笔记 id 存。
    private var conversionUndo: [String: String]?
    // 定时同步
    private var syncTimer: Timer?
    private var syncStartedAt = Date()
    private var lastSyncAttempt: Date?
    private var consecutiveSyncFailures = 0

    // MARK: - 备份与同步

    // MARK: - 启动

    init() {
        do {
            let db = try AppDatabase.makeOnDisk()
            self.database = db
            self.repo = GRDBNoteRepository(db: db)
        } catch {
            // 磁盘失败时退回内存库，至少让界面能起来。
            let db = try! AppDatabase.makeInMemory()
            self.database = db
            self.repo = GRDBNoteRepository(db: db)
            self.statusMessage = "磁盘数据库打开失败，已改用临时内存库：\(error.localizedDescription)"
        }
        appearance = AppearanceSettings.load()
        Theme.apply(appearance)
        providerSettings = providerService.settings
        loadAll(selectFirst: true)
        startSyncTimers()
    }

    // MARK: - 同步时机

    /// 定时同步 + 启动后一次。判定在 `SyncScheduler`，这里只负责触发。
    private func startSyncTimers() {
        syncStartedAt = Date()
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runScheduledSyncIfDue() }
        }
        // 启动后 10 秒拉一次：先把别的设备写的东西拿进来。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(SyncScheduler.startupDelay * 1_000_000_000))
            self.runStartupSyncIfNeeded()
        }
    }

    private func runStartupSyncIfNeeded() {
        guard syncSettings.isReadyToSync, !isSyncing else { return }
        performSyncWork({ sync in [try sync.sync().summary] }, done: { _ in })
    }

    private func runScheduledSyncIfDue() {
        let settings = syncSettings
        guard settings.isReadyToSync else { return }
        let due = SyncScheduler.shouldRun(
            now: Date(),
            startedAt: syncStartedAt,
            lastAttempt: lastSyncAttempt,
            consecutiveFailures: consecutiveSyncFailures,
            enabled: settings.backgroundSync,
            intervalMinutes: settings.syncIntervalMinutes,
            isSyncing: isSyncing,
            hasConflicts: !syncConflicts.isEmpty
        )
        guard due else { return }
        performSyncWork({ sync in [try sync.sync().summary] }, done: { _ in })
    }

    /// 立即同步一次。菜单、设置页、失焦节流都走这里。
    func syncNow() {
        performSyncWork({ sync in [try sync.sync().summary] }, done: { _ in })
    }

    /// 失焦后再同步一次的节流：距上次至少 5 分钟，避免每次切窗口都拉一遍。
    func syncOnResignActiveIfDue() {
        guard syncSettings.isReadyToSync, !isSyncing, syncConflicts.isEmpty else { return }
        if let last = lastSyncAttempt, Date().timeIntervalSince(last) < 300 { return }
        syncNow()
    }

    /// 设置页改完开关或间隔后调用，避免刚开就要等满一个周期。
    func rescheduleSync() {
        lastSyncAttempt = nil
        syncStartedAt = Date()
    }

    private func recordSyncOutcome(failure: String?) {
        lastSyncAttempt = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if let failure {
            consecutiveSyncFailures += 1
            syncStatusLine = "同步失败：" + failure
        } else {
            consecutiveSyncFailures = 0
            syncStatusLine = "已同步 " + formatter.string(from: Date())
        }
    }

    // MARK: - 载入

    func loadAll(selectFirst: Bool = false) {
        do {
            summaries = try repo.summaries()
            orphanCount = try repo.orphanCount()
            tags = try repo.allTags()
            resolvedKeys = Set(summaries.map { TextNormalizer.key($0.title) })
            if case .tag(let name) = sidebarScope, !tags.contains(where: { $0.name == name }) {
                sidebarScope = .all
            }

            if let id = selection, summaries.contains(where: { $0.id == id }) {
                loadNote(id: id)
            } else if selectFirst, let first = summaries.first {
                selection = first.id
                loadNote(id: first.id)
            } else {
                current = nil
                backlinks = []
                outgoing = []
                danglingTargets = []
                mentions = []
                aliases = []
            }
            refreshMentionGroups()
        } catch {
            statusMessage = "载入失败：\(error.localizedDescription)"
        }
    }

    func loadNote(id: String) {
        do {
            guard let note = try repo.note(id: id) else {
                current = nil
                return
            }
            current = note
            lastSavedBody = note.body
            backlinks = try repo.backlinks(to: id)
            outgoing = try repo.outgoing(from: id)
            danglingTargets = try repo.danglingTargets()
            mentions = try repo.mentions(in: id)
            aliases = try repo.aliases(noteId: id)
        } catch {
            statusMessage = "打开笔记失败：\(error.localizedDescription)"
        }
    }

    /// 全库提及聚合。批量面板与菜单状态用。
    func refreshMentionGroups() {
        mentionGroups = (try? repo.mentionGroups()) ?? []
    }

    // MARK: - 选择

    func select(_ id: String?) {
        guard let id else { return }
        flushPendingSave()
        selection = id
        loadNote(id: id)
    }

    /// 侧栏列表。搜索优先，其次是当前范围。
    func visibleSummaries() -> [NoteSummary] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.isEmpty else { return search(query: q) }
        switch sidebarScope {
        case .all, .search:
            return summaries
        case .orphans:
            return summaries.filter { $0.backlinkCount == 0 && $0.outgoingCount == 0 }
        case .tag(let name):
            let ids = Set(occurrenceSummaryIds(tagged: name))
            return summaries.filter { ids.contains($0.id) }
        }
    }

    /// 当前范围里笔记的数量。侧栏标题用。
    func visibleCount() -> Int { visibleSummaries().count }

    private func occurrenceSummaryIds(tagged name: String) -> [String] {
        (try? repo.summaries(tagged: name))?.map(\.id) ?? []
    }

    func selectScope(_ scope: SidebarScope) {
        sidebarScope = scope
        searchQuery = ""
    }

    /// `⌘P` Quick Open 的查询。
    func quickOpenItems(query: String, limit: Int = 12) -> [QuickOpenItem] {
        (try? repo.quickOpen(query: query, limit: limit)) ?? []
    }

    func filteredSummaries() -> [NoteSummary] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return summaries }
        do {
            return try repo.search(q)
        } catch {
            return summaries
        }
    }

    // MARK: - 新建

    func createNote(title: String) -> Note? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let note = try repo.create(title: trimmed)
            loadAll()
            select(note.id)
            isShowingNewNote = false
            return note
        } catch {
            statusMessage = "新建失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// `[[` 补全里选「新建」时调用。已存在同名笔记则直接返回它。
    func createIfNeeded(title: String) -> String? {
        let key = TextNormalizer.key(title)
        do {
            if let existing = try repo.summaries().first(where: { TextNormalizer.key($0.title) == key }) {
                return existing.title
            }
            let note = try repo.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines))
            loadAll()
            return note.title
        } catch {
            statusMessage = "新建失败：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - 保存

    /// 编辑区每改一次调用。500 ms 防抖后落库。
    func bodyDidChange(_ body: String) {
        guard var note = current else { return }
        note.body = body
        current = note

        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushPendingSave() }
        }
    }

    /// 立即落库。切换笔记、失焦、退出时调用。
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard var note = current else { return }
        guard note.body != lastSavedBody else { return }
        note.body = current?.body ?? note.body
        do {
            let saved = try repo.save(note)
            current = saved
            lastSavedBody = saved.body
            // 只刷新索引相关状态，不重建整表以免抖动
            let keepSelection = selection
            summaries = try repo.summaries()
            orphanCount = try repo.orphanCount()
            resolvedKeys = Set(summaries.map { TextNormalizer.key($0.title) })
            selection = keepSelection
            if let id = keepSelection {
                backlinks = try repo.backlinks(to: id)
                outgoing = try repo.outgoing(from: id)
                danglingTargets = try repo.danglingTargets()
                mentions = try repo.mentions(in: id)
            }
            refreshMentionGroups()
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func updateStatus(_ status: NoteStatus) {
        guard var note = current else { return }
        note.status = status
        current = note
        do {
            _ = try repo.save(note)
            loadAll()
        } catch {
            statusMessage = "状态保存失败：\(error.localizedDescription)"
        }
    }

    func deleteNote(id: String) {
        do {
            try repo.delete(id: id)
            // vault 里也删掉。导出本身只写不删，删除必须显式做，否则删了的笔记会在下次同步时复活。
            if syncSettings.isConfigured || !syncSettings.vaultPath.isEmpty {
                try? VaultSync(repo: repo, settings: syncSettings).removeFromVault(id: id)
            }
            if selection == id {
                selection = nil
                current = nil
            }
            loadAll(selectFirst: true)
        } catch {
            statusMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 引用导航

    /// 点击引用：已有则跳转，没有则按该标题新建再跳转。
    func openTitle(_ rawTitle: String) {
        let key = TextNormalizer.key(rawTitle)
        if let existing = summaries.first(where: { TextNormalizer.key($0.title) == key }) {
            select(existing.id)
            return
        }
        _ = createIfNeeded(title: rawTitle)
        if let created = summaries.first(where: { TextNormalizer.key($0.title) == key }) {
            select(created.id)
        }
    }

    // MARK: - 外观

    /// 应用新的外观设置：先夹取，再套用，最后落 UserDefaults。
    func updateAppearance(_ settings: AppearanceSettings) {
        let clamped = settings.clamped
        appearance = clamped
        Theme.apply(clamped)
        clamped.save()
    }

    func resetAppearance() {
        updateAppearance(AppearanceSettings())
    }

    // MARK: - 模型服务

    /// 重新读一遍 provider 列表与密钥状态。设置页出现时调用。
    func refreshProviders() {
        providerSettings = providerService.settings
        var ready = Set<UUID>()
        for provider in providerSettings.providers where providerService.hasSecret(for: provider.id) {
            ready.insert(provider.id)
        }
        providersWithKey = ready
    }

    @discardableResult
    func saveProvider(_ config: ProviderConfig, secret: String?) -> [String] {
        let errors = providerService.upsert(config, secret: secret)
        refreshProviders()
        return errors
    }

    func deleteProvider(_ id: UUID) {
        providerService.delete(id)
        refreshProviders()
    }

    func bindProvider(_ role: ProviderRole, to id: UUID?) {
        providerService.bind(role, to: id)
        refreshProviders()
    }

    func maskedKey(for id: UUID) -> String? {
        providerService.maskedSecret(for: id)
    }

    func hasKey(for id: UUID) -> Bool {
        providersWithKey.contains(id)
    }

    func testProvider(_ id: UUID, role: ProviderRole) async -> ProbeResult {
        guard let config = providerSettings.provider(id: id) else {
            return ProbeResult(ok: false, message: "找不到这个服务", latencyMs: 0, detail: "")
        }
        let key = providerService.secret(for: id) ?? ""
        if config.requiresKey && key.isEmpty {
            return ProbeResult(ok: false, message: "先填密钥再测试", latencyMs: 0, detail: "")
        }
        return await ProviderProbe.run(config: config, key: key, role: role)
    }

    func exportProviderConfig() -> Data? { providerService.exportJSON() }

    @discardableResult
    func importProviderConfig(_ data: Data) -> [String] {
        let messages = providerService.importJSON(data)
        refreshProviders()
        return messages
    }

    /// 恢复全部设置：外观回默认、清空服务商与密钥。
    func resetAllSettings() {
        providerService.resetAll(alsoAppearance: true)
        appearance = AppearanceSettings()
        Theme.apply(appearance)
        refreshProviders()
    }

    func rebuildIndexes() {
        do {
            try repo.rebuildAllIndexes()
            loadAll()
            statusMessage = "索引已重建。"
        } catch {
            statusMessage = "重建失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 提及（L2）

    /// 当前笔记的提及区间与目标标题。编辑区用它画点状下划线。
    func mentionDecorations() -> [MentionDecoration] {
        mentions.map {
            MentionDecoration(
                range: NSRange(location: $0.location, length: $0.length),
                title: $0.targetTitle
            )
        }
    }

    func dismissMention(id: Int64) {
        do {
            try repo.dismissMention(id: id)
            reloadCurrent()
        } catch {
            statusMessage = "忽略提及失败：\(error.localizedDescription)"
        }
    }

    var canUndoConversion: Bool { conversionUndo != nil }

    /// 把提及转成引用。整批一个事务，失败不改任何正文。
    @discardableResult
    func convertMentions(ids: [Int64]) -> Bool {
        guard !ids.isEmpty else { return false }
        flushPendingSave()
        do {
            let conversions = try repo.convertMentions(occurrenceIds: ids)
            guard !conversions.isEmpty else {
                reloadCurrent()
                return false
            }
            conversionUndo = Dictionary(uniqueKeysWithValues: conversions.map { ($0.id, $0.previousBody) })
            let inserted = conversions.reduce(0) { $0 + $1.insertedCount }
            let summary = "已把 \(inserted) 处提及转成引用，涉及 \(conversions.count) 篇笔记。"
            lastConversionSummary = summary
            loadAll()
            reloadCurrent()
            statusMessage = summary
            return true
        } catch {
            statusMessage = "转换失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 单个目标在全部笔记里的提及 id。侧栏「全部转换」用。
    func occurrenceIds(forTarget targetId: String) -> [Int64] {
        mentionGroups.first { $0.targetId == targetId }?.occurrences.map(\.id) ?? []
    }

    /// 只算不改，供 diff 预览。
    func previewMentionConversion(ids: [Int64]) -> [NoteConversion] {
        (try? repo.previewMentionConversion(occurrenceIds: ids)) ?? []
    }

    func undoLastConversion() {
        guard let undo = conversionUndo else { return }
        do {
            try repo.restoreBodies(undo)
            conversionUndo = nil
            lastConversionSummary = nil
            loadAll()
            reloadCurrent()
            statusMessage = "已撤销上次批量转换。"
        } catch {
            statusMessage = "撤销失败：\(error.localizedDescription)"
        }
    }

    private func reloadCurrent() {
        if let id = selection { loadNote(id: id) }
        refreshMentionGroups()
    }

    // MARK: - 别名

    /// 加别名。返回错误说明，nil 表示成功。
    func addAlias(_ name: String) -> String? {
        guard let id = selection else { return "没有选中笔记" }
        do {
            let message = try repo.addAlias(noteId: id, name: name)
            if message == nil {
                aliases = try repo.aliases(noteId: id)
                loadAll()
                reloadCurrent()
            }
            return message
        } catch {
            return error.localizedDescription
        }
    }

    func removeAlias(_ name: String) {
        guard let id = selection else { return }
        do {
            _ = try repo.removeAlias(noteId: id, name: name)
            aliases = try repo.aliases(noteId: id)
            loadAll()
            reloadCurrent()
        } catch {
            statusMessage = "删除别名失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 改名

    func renameImpact(newTitle: String) -> [RenameImpact] {
        guard let id = selection else { return [] }
        return (try? repo.renameImpact(noteId: id, newTitle: newTitle)) ?? []
    }

    /// 改名并批量重写正文引用。返回错误说明，nil 表示成功。
    func rename(newTitle: String) -> String? {
        guard let id = selection else { return "没有选中笔记" }
        flushPendingSave()
        do {
            let changed = try repo.rename(noteId: id, newTitle: newTitle)
            selection = id
            loadAll()
            reloadCurrent()
            isShowingRenameSheet = false
            statusMessage = changed > 0
                ? "已改名，并改写了 \(changed) 篇笔记里的旧引用。"
                : "已改名。"
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func completionItems(query: String, limit: Int) -> [CompletionItem] {
        (try? repo.completionItems(query: query, limit: limit)) ?? []
    }

    func search(query: String) -> [NoteSummary] {
        (try? repo.search(query)) ?? []
    }

    func duplicateTitleExists(_ title: String) -> Bool {
        let key = TextNormalizer.key(title)
        return summaries.contains { TextNormalizer.key($0.title) == key }
    }

    /// 建新笔记前的查重：按标题字符二元组做 Jaccard，取前 3。
    func similarNotes(for title: String, limit: Int = 3) -> [(summary: NoteSummary, score: Double)] {
        let target = Self.bigrams(TextNormalizer.key(title))
        guard !target.isEmpty else { return [] }
        var scored: [(NoteSummary, Double)] = []
        for note in summaries {
            let other = Self.bigrams(TextNormalizer.key(note.title))
            guard !other.isEmpty else { continue }
            let inter = target.intersection(other).count
            let union = target.union(other).count
            let score = Double(inter) / Double(max(union, 1))
            if score >= 0.2 { scored.append((note, score)) }
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
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

    func setCompletionVisible(_ visible: Bool) {
        isCompletionVisible = visible
    }

    func clearStatus() {
        statusMessage = nil
    }
}

// MARK: - 备份与同步

extension AppState {

    #if DEBUG
    /// 仅 DEBUG：取证用，直接塞一组冲突。
    func debugSetConflicts(_ conflicts: [VaultConflict]) {
        syncConflicts = conflicts
    }
    #endif

    /// 用 LLM 合并一处冲突。返回合并后的正文，失败给中文原因。
    func resolveConflictWithLLM(_ conflict: VaultConflict) async -> Result<String, LLMError> {
        guard let effective = providerService.effective(.chat) else {
            let reason = providerService.unavailableReason(.chat) ?? "没有可用的对话模型"
            return .failure(LLMError(message: "需要先在「设置 → 模型服务」里配置对话模型：\(reason)"))
        }
        return await ConflictResolver.resolve(conflict, provider: effective.config, key: effective.key)
    }

    /// 采用合并结果：写回笔记、重算索引、导出到 vault。
    func applyConflictResolution(_ conflict: VaultConflict, body: String) -> String? {
        guard var note = try? repo.note(id: conflict.noteId) else { return "笔记不存在" }
        note.body = body
        do {
            _ = try repo.save(note)
            syncConflicts.removeAll { $0.noteId == conflict.noteId }
            if syncSettings.isConfigured || !syncSettings.vaultPath.isEmpty {
                let sync = VaultSync(repo: repo, settings: syncSettings)
                DispatchQueue.global(qos: .utility).async {
                    try? sync.exportAll()
                    let git = sync.git
                    if git.isRepository(), git.hasLocalChanges() {
                        try? git.stageAll()
                        if git.stagedChangesExist() {
                            try? git.commit("resolve: \(conflict.title)")
                        }
                    }
                }
            }
            loadAll()
            reloadCurrent()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func saveSyncSettings(_ settings: SyncSettings) {
        syncSettings = settings
        settings.save()
    }

    /// 后台跑一次 vault 操作，回到主线程刷新界面。
    ///
    /// 不同步放在主线程：git 一次拉推可能几百毫秒，卡住界面比慢一点更糟。
    func performSyncWork(
        _ work: @escaping (VaultSync) throws -> [String],
        done: @escaping ([String]) -> Void
    ) {
        guard !isSyncing else { return }
        isSyncing = true
        flushPendingSave()
        let settings = syncSettings
        let repo = self.repo

        DispatchQueue.global(qos: .userInitiated).async {
            let sync = VaultSync(repo: repo, settings: settings)
            var lines: [String] = []
            var failure: String?
            do {
                lines = try work(sync)
            } catch let err {
                failure = err.localizedDescription
            }
            let conflicts = sync.lastConflicts

            DispatchQueue.main.async {
                var settings = settings
                if failure == nil {
                    settings.lastSyncedAt = Int64(Date().timeIntervalSince1970 * 1000)
                    settings.lastMessage = lines.first ?? ""
                } else {
                    settings.lastMessage = "失败：\(failure ?? "")"
                }
                self.syncSettings = settings
                settings.save()
                self.isSyncing = false
                if failure == nil { self.syncConflicts = conflicts }
                self.recordSyncOutcome(failure: failure)
                self.loadAll()
                done(failure.map { ["错误：" + $0] } ?? lines)
            }
        }
    }
}
