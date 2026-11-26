import AppKit
import Foundation
import SwiftUI

/// 单一状态源。界面只与它对话。
@MainActor
final class AppState: ObservableObject {

    // MARK: - 发布状态

    @Published private(set) var summaries: [NoteSummary] = []
    /// 导航状态：当前模块、每模块的范围、选中与搜索词。
    @Published private(set) var nav = NavigationState()
    /// 当前模块选中的条目 id。读写都落到 `nav`，只留一个真相。
    var selection: String? {
        get { nav.selection }
        set { nav.setSelection(newValue) }
    }
    @Published var current: Note?
    @Published private(set) var backlinks: [Backlink] = []
    @Published private(set) var outgoing: [NoteLink] = []
    @Published private(set) var danglingTargets: [String] = []
    @Published private(set) var orphanCount: Int = 0
    /// 普通笔记数。「全部」的条数，不含日记。
    @Published private(set) var noteCount: Int = 0
    /// 侧栏「日记」列表，按日期倒序。
    @Published private(set) var journalEntries: [JournalEntry] = []
    /// 待办总览，跨全部日记聚合。
    @Published private(set) var todoOverview: [JournalTodo] = []
    /// 未完成待办条数。模块导航的「待办总览」用。
    @Published private(set) var journalOpenTodoCount: Int = 0
    /// 模板个数。模块导航的「模板」用。
    @Published private(set) var journalTemplateCount: Int = 0
    /// 当前模块的搜索词。各模块各存各的，切走不丢。
    var searchQuery: String {
        get { nav.query }
        set { nav.setQuery(newValue) }
    }
    /// 日记是否参与未链接提及扫描。设置入口在右侧面板，值落 UserDefaults。
    @Published private(set) var journalScanMentions: Bool = JournalMentionSettings.scanMentions
    /// 外观设置。改动即时生效并落 UserDefaults。
    @Published private(set) var appearance: AppearanceSettings = .init()
    /// 模型服务设置。密钥在 Keychain，这里只有非敏感部分。
    @Published private(set) var providerSettings = ProviderSettings()
    /// 剪藏设置。改动即时生效并落 UserDefaults。
    @Published var clipSettings = ClipSettings.load()
    /// 全部剪藏（列表模型，不含正文）。
    @Published var clipSummaries: [ClipSummary] = []
    /// 剪藏标签，只出现在剪藏范围。
    @Published var clipTags: [TagCount] = []
    @Published var clipUnreadCount: Int = 0
    @Published var clipTotalCount: Int = 0
    @Published var clipArchivedCount: Int = 0

    /// 待整理：正文已存、模型还没整理完。
    var clipPendingCount: Int { clipSummaries.filter { $0.aiState != .done }.count }
    @Published var isShowingNewClip: Bool = false
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
    @Published var statusMessage: String?
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

    var repo: GRDBNoteRepository
    private let database: AppDatabase
    /// 模型服务的读写与校验。密钥走 Keychain。
    let providerService = ProviderService()
    private var saveTask: Task<Void, Never>?
    /// 最近一次落库的正文，用于跳过无变化的保存。
    var lastSavedBody: String = ""

    /// 正文被**外部**改写的次数（改名、批量转换、撤销转换、日记承接、冲突合并、重载）。
    ///
    /// 编辑器只在它变化时接受外部正文。用户自己敲的字走 `bodyDidChange`，不动这个值。
    /// 不用它的话，`updateNSView` 拿到一次旧快照就会把刚敲的字整段冲掉（issue #34）。
    @Published private(set) var bodyRevision: Int = 0
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
        // 设置里的日记提及开关要进仓库：保存链路靠它决定扫不扫日记。
        repo.journalScanMentions = JournalMentionSettings.scanMentions
        journalScanMentions = repo.journalScanMentions
        appearance = AppearanceSettings.load()
        Theme.apply(appearance)
        providerSettings = providerService.settings
        healFromVault()
        // 开关开着时，启动先补齐日记的提及：否则上次关着的历史日记一直没扫过。
        if journalScanMentions { try? repo.reindexJournalMentions() }
        loadAll(selectFirst: true)
        startSyncTimers()
    }

    /// 启动自愈：先把库里已有内容补写一份到当前 vault（当前目录空了才写），再从 vault 重建缺失的东西。
    private func healFromVault() {
        do {
            var messages: [String] = []
            if let seeded = try repo.seedVaultIfNeeded() { messages.append(seeded) }
            if let repaired = try repo.repairFromVaultIfNeeded() { messages.append(repaired) }
            guard !messages.isEmpty else { return }
            let line = messages.joined(separator: "；")
            statusMessage = [statusMessage, line].compactMap { $0 }.joined(separator: "；")
            DebugLog.write("heal: \(line)")
        } catch {
            statusMessage = "vault 自愈失败：\(error.localizedDescription)"
        }
    }

    #if DEBUG
    /// 仅测试：注入内存库与临时 vault，跳过磁盘库、vault 自愈与定时同步。
    init(repo: GRDBNoteRepository, clipSettings: ClipSettings = ClipSettings()) {
        self.database = repo.db
        self.repo = repo
        self.clipSettings = clipSettings
        self.appearance = AppearanceSettings.load()
        self.providerSettings = providerService.settings
        loadAll(selectFirst: false)
        refreshClips()
    }
    #endif

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

    // MARK: - 布局

    /// 窗口内容宽度。窄于 `narrowWidth` 时列表栏自动收起。
    @Published private(set) var windowWidth: CGFloat = 1400
    /// 列表栏是否展开。用户手动改，落 UserDefaults。
    @Published private(set) var listPaneExpanded = ListPaneSettings.isVisible
    /// 窄窗口下手动展开过列表栏。拉宽后清掉，回到手动状态。
    @Published private(set) var narrowListOverride: Bool?

    /// 窄窗口门槛。低于这个宽度让列表栏让位给内容区。
    static let narrowWidth: CGFloat = 1000
    /// 列表栏宽度，可拖可记。范围见 `ListPaneSettings.width`。
    @Published private(set) var listPaneWidth = ListPaneSettings.width
    /// 模块导航是否收成一列图标。
    @Published private(set) var isNavCollapsed = ListPaneSettings.navCollapsed

    /// 收起或展开模块导航。收起后只留一列图标，范围与标签藏起来。
    func toggleNavPane() {
        isNavCollapsed.toggle()
        ListPaneSettings.navCollapsed = isNavCollapsed
    }

    var isNarrowWindow: Bool { windowWidth < Self.narrowWidth }

    /// 列表栏现在是否可见。窄窗口默认收起，手动展开后按手动值。
    var isListPaneVisible: Bool {
        isNarrowWindow ? (narrowListOverride ?? false) : listPaneExpanded
    }

    func setWindowWidth(_ width: CGFloat) {
        guard abs(width - windowWidth) > 0.5 else { return }
        let wasNarrow = isNarrowWindow
        windowWidth = width
        // 从窄拉宽：丢掉窄窗口下的临时展开，回到上次手动状态。
        if wasNarrow && !isNarrowWindow {
            narrowListOverride = nil
        }
    }

    /// 拖动列表栏分隔条。夹在 200–360，改完立刻落盘。
    func setListPaneWidth(_ width: CGFloat) {
        let clamped = min(max(width, 200), 360)
        guard abs(clamped - listPaneWidth) > 0.5 else { return }
        listPaneWidth = clamped
        ListPaneSettings.width = clamped
    }

    /// 收起或展开列表栏。宽窗口记进 UserDefaults，窄窗口只记临时展开。
    func toggleListPane() {
        if isNarrowWindow {
            narrowListOverride = !(narrowListOverride ?? false)
        } else {
            listPaneExpanded.toggle()
            ListPaneSettings.isVisible = listPaneExpanded
        }
    }

    /// 换范围：清搜索词，选中落到新范围的第一条。
    func applyScope(_ scope: ModuleScope) {
        guard scope.module == nav.active else { return }
        flushPendingSave()
        nav.setScope(scope)
        searchQuery = ""
        // 待办总览的数据只在打开时算，切到这一页就刷新一次。
        if case .journal(.todos) = nav.scope {
            todoOverview = (try? repo.todoOverview()) ?? []
        }
        restoreSelectionForActiveModule()
    }

    /// 切模块。记住的目标模块范围与选中都还原，不清搜索词。
    func selectModule(_ module: AppModule) {
        guard nav.active != module else { return }
        flushPendingSave()
        nav.enter(module)
        restoreSelectionForActiveModule()
    }

    /// 切到模块后把选中落到它记住的那条；没有就选当前范围的第一条。
    func restoreSelectionForActiveModule() {
        switch nav.active {
        case .notes:
            let ids = visibleSummaries().map(\.id)
            restoreSelection(from: ids)
        case .journal:
            // 总览与模板没有列表，选中保持不动。
            if case .todos = nav.journalScope { return }
            if case .templates = nav.journalScope { return }
            var ids = journalEntries.map(\.id)
            if case .today = nav.journalScope {
                let today = JournalDate.today()
                ids = journalEntries.filter { $0.date == today }.map(\.id)
            }
            restoreSelection(from: ids)
        case .clips:
            refreshClips()
            let ids = visibleClips.map(\.id)
            if let id = nav.selection, ids.contains(id) {
                loadNote(id: id)
                return
            }
            if let first = ids.first {
                select(first)
            } else {
                selection = nil
                current = nil
            }
        }
    }

    private func restoreSelection(from ids: [String]) {
        if let id = nav.selection, ids.contains(id) {
            loadNote(id: id)
            return
        }
        if let first = ids.first {
            selection = first
            loadNote(id: first)
        } else {
            selection = nil
            current = nil
        }
    }

    // MARK: - 载入

    func loadAll(selectFirst: Bool = false) {
        do {
            summaries = try repo.summaries()
            orphanCount = try repo.orphanCount()
            noteCount = try repo.noteCount()
            journalEntries = try repo.journalEntries()
            journalOpenTodoCount = (try? repo.todoOverview())?.count ?? 0
            journalTemplateCount = JournalTemplates.load(in: repo.vaultURL).count
            tags = try repo.allTags(types: repo.mainListTypes)
            refreshClips()
            resolvedKeys = Set(summaries.map { TextNormalizer.key($0.title) })
            if case .tag(let name) = nav.noteScope, !tags.contains(where: { $0.name == name }) {
                nav.setScope(.note(.all))
            }

            if let id = selection, summaries.contains(where: { $0.id == id }) {
                loadNote(id: id)
            } else if selectFirst,
                      let first = summaries.first(where: { NoteTypes.descriptor(for: $0.type).inMainList }) {
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
            // 从库里重新读出来 = 外部改写，编辑器要接收这次正文。
            bodyRevision &+= 1
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
        markOpenedClipReadIfNeeded(id: id)
    }

    /// 打开剪藏时按设置自动标已读。放在统一的选择入口，侧栏、⌘P、右栏跳转都会命中。
    private func markOpenedClipReadIfNeeded(id: String) {
        guard clipSettings.markReadOnOpen,
              let note = current, note.id == id,
              note.type == NoteTypes.clipID,
              note.metaFields[ClipFields.status] == ClipStatus.unread.rawValue
        else { return }
        setClipStatus(id: id, status: .read)
    }

    /// 侧栏列表。搜索优先，其次是当前范围。
    ///
    /// 「全部」= 普通笔记，日记单独一层；孤儿也排除日记。
    /// 搜索命中在「含日记」时会带上日记。
    func visibleSummaries() -> [NoteSummary] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if nav.active == .clips { return [] }
        if !q.isEmpty {
            return (try? repo.search(q, types: searchTypes)) ?? []
        }
        guard nav.active == .notes else { return [] }
        switch nav.noteScope {
        case .all:
            return noteSummaries
        case .orphans:
            return noteSummaries.filter { $0.backlinkCount == 0 && $0.outgoingCount == 0 }
        case .tag(let name):
            let ids = Set(occurrenceSummaryIds(tagged: name))
            return noteSummaries.filter { ids.contains($0.id) }
        }
    }

    /// 当前模块搜索要查哪些类型。每个模块只查自己的，互不串。
    var searchTypes: Set<String> {
        switch nav.active {
        case .clips:
            return [NoteTypes.clipID]
        case .journal:
            return [NoteTypes.journalID]
        case .notes:
            return Set(repo.mainListTypes)
        }
    }

    /// 普通笔记（不含日记）。所有「全部 / 孤儿 / 标签」列表都从这里过滤。
    var noteSummaries: [NoteSummary] {
        summaries.filter { NoteTypes.descriptor(for: $0.type).inMainList }
    }

    /// 搜索结果里的日记命中。侧栏把日记单独渲染成日期行。
    ///
    /// 目前侧栏直接从 `visibleSummaries()` 里按 `isJournal` 分组，不重复查库。
    func journalSearchHits() -> [NoteSummary] {
        visibleSummaries().filter(\.isJournal)
    }

    /// 当前范围里笔记的数量。侧栏标题用。
    func visibleCount() -> Int { visibleSummaries().count }

    private func occurrenceSummaryIds(tagged name: String) -> [String] {
        (try? repo.summaries(tagged: name, types: repo.mainListTypes))?.map(\.id) ?? []
    }

    /// 切模块并指定范围。范围与模块不匹配时只切模块。
    func enterModule(_ module: AppModule, scope: ModuleScope) {
        nav.enter(module, scope: scope)
    }

    /// 只改当前模块的范围。
    func setModuleScope(_ moduleScope: ModuleScope) {
        nav.setScope(moduleScope)
    }

    /// `⌘N`：按当前模块分流。笔记 → 新建笔记；日记 → 今天；剪藏 → 新建剪藏。
    func newInActiveModule() {
        switch nav.active {
        case .notes: isShowingNewNote = true
        case .journal: goToToday()
        case .clips: isShowingNewClip = true
        }
    }

    /// `⌘N` 菜单标题，跟着模块变。
    var newInActiveModuleTitle: String {
        switch nav.active {
        case .notes: return "新建笔记"
        case .journal: return "打开今天的日记"
        case .clips: return "新建剪藏…"
        }
    }

    /// `⌘P` Quick Open 的查询。
    func quickOpenItems(query: String, limit: Int = 12) -> [QuickOpenItem] {
        (try? repo.quickOpen(query: query, limit: limit)) ?? []
    }

    func filteredSummaries() -> [NoteSummary] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return summaries }
        do {
            return try repo.search(q, types: searchTypes)
        } catch {
            return summaries
        }
    }

    // MARK: - 日记

    /// 打开某天的日记；不存在就按模板与承接新建。`⌘⇧J` 与演示数据都走这里。
    ///
    /// `templates` 传 nil 时按「模板…」记住的选择取，记忆失效才退回 order 最小的前两个。
    @discardableResult
    func openJournal(on date: String, using templates: [String]? = nil) -> Note? {
        flushPendingSave()
        do {
            let names = templates ?? JournalTemplates.newJournalNames(in: repo.vaultURL)
            let note = try repo.journalNote(on: date, using: names)
            loadAll()
            nav.enter(.journal, scope: .journal(.all))
            searchQuery = ""
            selection = note.id
            loadNote(id: note.id)
            return note
        } catch {
            DebugLog.write("openJournal(\(date)) failed: \(error.localizedDescription)")
            statusMessage = "打开日记失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// `⌘⇧J`：打开今天。没有就建。
    func goToToday() {
        _ = openJournal(on: JournalDate.today())
    }

    // MARK: - 日记承接（C02 / C06）

    /// 「插入承接（当前行之前）」：把上一篇日记的未完成项插到光标所在行之前。
    ///
    /// 光标行从编辑区的 `NSTextView.selectedRange()` 换算；没有可用编辑区时按第 0 行（文首）。
    /// 判重、空行规则、光标落点都在 `JournalCarry.insertion`，这里只负责取光标、落库、给提示。
    @discardableResult
    func insertCarryAtCaret() -> Bool {
        flushPendingSave()
        guard let note = current, note.type == NoteTypes.journalID else {
            statusMessage = "只有日记能插入承接。"
            return false
        }
        guard let day = note.metaFields["date"], !day.isEmpty else { return false }
        guard let previous = try? repo.previousJournal(before: day),
              let previousDay = previous.metaFields["date"] else {
            statusMessage = "没有更早的日记可承接。"
            return false
        }
        let short = JournalTodo.short(previousDay)
        if JournalCarry.hasCarry(in: note.body, from: previousDay) {
            statusMessage = "\(short) 的承接已经在正文里了，不重复插入。"
            return false
        }
        let items = JournalCarry.openTodos(in: previous.body)
        guard !items.isEmpty else {
            statusMessage = "\(short) 没有未完成项。"
            return false
        }

        let body = note.body
        let line = editorCaretLine(matching: body)
        let result = JournalCarry.insertion(into: body, beforeLine: line, from: previousDay, items: items)
        guard result.didInsert else {
            statusMessage = "承接没有插入：\(short) 已经在正文里了。"
            return false
        }

        var updated = note
        updated.body = result.body
        var meta = note.metaFields
        meta["carryFrom"] = previousDay
        updated.setMetaFields(meta)
        do {
            let saved = try repo.save(updated)
            loadAll()
            nav.enter(.journal, scope: .journal(.all))
            searchQuery = ""
            selection = saved.id
            loadNote(id: saved.id)
            statusMessage = "承接 \(items.count) 条，插在第 \(line + 1) 行之前。"
            placeCaret(onLine: result.caretLine, in: result.body)
            return true
        } catch {
            statusMessage = "插入承接失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 编辑区光标所在行（0-based）。找不到编辑区时退回第 0 行。
    private func editorCaretLine(matching body: String) -> Int {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let textView = Self.editorTextView(in: window.contentView!, matching: body) else { return 0 }
        return JournalCarry.lineIndex(ofUTF16Offset: textView.selectedRange().location, in: textView.string)
    }

    /// 插入后把光标放到承接块之后的那一行。
    private func placeCaret(onLine line: Int, in body: String) {
        guard let offset = JournalCarry.utf16Offset(ofLine: line, in: body) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let textView = Self.editorTextView(in: window.contentView!, matching: body) else { return }
            textView.window?.makeFirstResponder(textView)
            let target = min(offset, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: target, length: 0))
            textView.scrollRangeToVisible(NSRange(location: target, length: 0))
        }
    }

    // MARK: - 日记模板（记忆 + 「模板…」）

    /// 「模板…」里的候选：vault 里全部模板，按 order 升序。
    func journalTemplateChoices() -> [JournalTemplate] {
        JournalTemplates.load(in: repo.vaultURL)
            .sorted { a, b in a.order != b.order ? a.order < b.order : a.name < b.name }
    }

    /// 下一次新建日记会用的模板名（记忆优先，失效退回默认）。
    func journalTemplateNames() -> [String] {
        JournalTemplates.newJournalNames(in: repo.vaultURL)
    }

    /// 不带记忆的默认模板名：order 最小的前 `limit` 个。
    func defaultJournalTemplateNames(limit: Int = 2) -> [String] {
        JournalTemplates.defaultNames(in: repo.vaultURL, limit: limit)
    }

    /// 面板里保存一份模板：`existing` 为 nil 时新建，否则覆盖（含改名）。
    ///
    /// 落盘格式由 `JournalTemplates.create/update` 决定，这里只补一条状态提示。
    /// 下一次 `⌘⇧J` 会重新读目录，所以保存后立刻生效，不用重启。
    @discardableResult
    func saveJournalTemplate(
        _ existing: JournalTemplate?,
        name: String,
        order: String,
        body: String
    ) throws -> JournalTemplate {
        let saved: JournalTemplate
        if let existing {
            saved = try JournalTemplates.update(existing, name: name, order: order, body: body, in: repo.vaultURL)
            // 改名后记忆里的旧名字换成新名字，否则下次新建会以为模板没了。
            let remembered = JournalTemplateMemory.names
            if saved.name != existing.name, remembered.contains(existing.name) {
                JournalTemplateMemory.names = remembered.map { $0 == existing.name ? saved.name : $0 }
            }
        } else {
            saved = try JournalTemplates.create(name: name, order: order, body: body, in: repo.vaultURL)
        }
        statusMessage = existing == nil ? "模板已新建：\(saved.name)" : "模板已保存：\(saved.name)"
        return saved
    }

    /// 面板里删除一份模板。记忆里留着已删掉的名字没有意义，顺手清掉。
    func deleteJournalTemplate(_ template: JournalTemplate) throws {
        try JournalTemplates.delete(template, in: repo.vaultURL)
        let remembered = JournalTemplateMemory.names
        if remembered.contains(template.name) {
            JournalTemplateMemory.names = remembered.filter { $0 != template.name }
        }
        statusMessage = "模板已删除：\(template.name)"
    }

    /// 「模板…」确认：覆盖记忆。只影响之后新建的日记，不改已有日记正文。
    func setJournalTemplateNames(_ names: [String]) {
        JournalTemplateMemory.names = names
        let applied = journalTemplateNames()
        statusMessage = applied.isEmpty
            ? "下次新建日记不加模块骨架。"
            : "下次新建日记将用：\(applied.joined(separator: "、"))。"
    }

    /// `⌘⇧T`：刷新待办总览并打开面板。只聚合已经存在的日记，不代为新建。
    /// `⌘⇧T`：切到日记模块的「待办总览」，占中栏。
    func openTodoOverview() {
        flushPendingSave()
        todoOverview = (try? repo.todoOverview()) ?? []
        nav.enter(.journal, scope: .journal(.todos))
    }

    /// 从待办总览跳到「最近出现」那天，并把那一行滚到可见。
    func jumpToTodo(_ todo: JournalTodo) {
        guard let note = try? repo.journal(on: todo.lastDate) else {
            statusMessage = "找不到 \(todo.lastDate) 的日记"
            return
        }
        flushPendingSave()
        nav.enter(.journal, scope: .journal(.all))
        searchQuery = ""
        selection = note.id
        loadNote(id: note.id)
        revealInEditor(todo.text)
    }

    /// 日记的提及开关。改完立即重扫全部日记，右栏当场能看到变化。
    func setJournalScanMentions(_ enabled: Bool) {
        JournalMentionSettings.scanMentions = enabled
        journalScanMentions = enabled
        repo.journalScanMentions = enabled
        do {
            try repo.reindexJournalMentions()
            reloadCurrent()
            statusMessage = enabled ? "日记已参与提及扫描。" : "日记不再参与提及扫描。"
        } catch {
            statusMessage = "重扫日记提及失败：\(error.localizedDescription)"
        }
    }

    /// 在编辑区里选中并滚到某段文字。找不到就什么都不做。
    func revealInEditor(_ text: String) {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let textView = Self.findTextView(in: window.contentView!) else { return }
            let full = textView.string as NSString
            let range = full.range(of: needle)
            guard range.location != NSNotFound else { return }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    /// 正文与 `body` 一致的编辑区。窗口里还有搜索框的 field editor，不能只取第一个 `NSTextView`。
    private static func editorTextView(in view: NSView, matching body: String) -> NSTextView? {
        var candidates: [NSTextView] = []
        collectTextViews(in: view, into: &candidates)
        return candidates.first { $0.string == body } ?? candidates.first
    }

    private static func collectTextViews(in view: NSView, into out: inout [NSTextView]) {
        if let textView = view as? NSTextView { out.append(textView) }
        for sub in view.subviews { collectTextViews(in: sub, into: &out) }
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
        clipSettings = ClipSettings()
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
        (try? repo.search(query, types: searchTypes)) ?? []
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
        for note in summaries where note.type == NoteTypes.noteID {
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

    /// vault 目录。模板管理等界面要用，不能只在 DEBUG 下存在。
    var vaultURL: URL { repo.vaultURL }

    #if DEBUG
    /// 仅 DEBUG：取证用，直接塞一组冲突。
    func debugSetConflicts(_ conflicts: [VaultConflict]) {
        syncConflicts = conflicts
    }


    /// 仅 DEBUG：取证用，不经编辑器直接写一篇日记的正文。
    func debugSeedJournal(on date: String, body: String) {
        flushPendingSave()
        guard let existing = try? repo.journalNote(on: date, using: []) else { return }
        var note = existing
        note.body = body
        _ = try? repo.save(note)
        loadAll()
    }

    /// 仅 DEBUG：取证用，把光标放到含 `keyword` 的段落之后回报行号。
    @discardableResult
    func debugPlaceCaret(atKeyword keyword: String) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let textView = Self.findTextView(in: window.contentView!) else { return false }
        let range = (textView.string as NSString).range(of: keyword)
        guard range.location != NSNotFound else { return false }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        return true
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
                let syncClips = syncSettings.syncClips
                DispatchQueue.global(qos: .utility).async {
                    try? sync.exportAll()
                    let git = sync.git
                    let excludes: [String] = syncClips
                        ? []
                        : [VaultFormat.noteDir(for: NoteTypes.clipID)]
                    if git.isRepository(), git.hasLocalChanges(excluding: excludes) {
                        try? git.stageAll(excluding: excludes)
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
        let previousVault = syncSettings.vaultURL.standardizedFileURL
        syncSettings = settings
        settings.save()
        // 保存先写 vault，目录得跟着设置走，否则改完目录还会往旧目录写。
        repo.vaultURL = settings.vaultURL
        // 换到另一个目录：新目录可能是空的，当场补一次播种，不用等下次启动。
        if settings.vaultURL.standardizedFileURL != previousVault {
            healFromVault()
        }
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
