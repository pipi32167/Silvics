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
    @Published private(set) var statusMessage: String?
    @Published var isShowingNewNote: Bool = false
    @Published private(set) var isCompletionVisible: Bool = false
    /// 已解析的标题键集合。驱动引用是实线还是虚线。
    @Published private(set) var resolvedKeys: Set<String> = []

    // MARK: - 内部

    private let repo: GRDBNoteRepository
    private let database: AppDatabase
    private var saveTask: Task<Void, Never>?
    /// 最近一次落库的正文，用于跳过无变化的保存。
    private var lastSavedBody: String = ""

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
            resolvedKeys = Set(summaries.map { TextNormalizer.key($0.title) })

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
            }
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
        } catch {
            statusMessage = "打开笔记失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 选择

    func select(_ id: String?) {
        guard let id else { return }
        flushPendingSave()
        selection = id
        loadNote(id: id)
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
            }
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
