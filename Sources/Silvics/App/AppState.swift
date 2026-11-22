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

    // MARK: - 内部

    private let repo: GRDBNoteRepository
    private let database: AppDatabase
    private var saveTask: Task<Void, Never>?
    /// 最近一次落库的正文，用于跳过无变化的保存。
    private var lastSavedBody: String = ""
    /// 上次批量转换前的正文。按笔记 id 存。
    private var conversionUndo: [String: String]?

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
        loadAll(selectFirst: true)
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
