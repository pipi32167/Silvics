import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var app: AppState

    private var query: String {
        app.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 搜索命中或当前范围的笔记。日记与普通笔记混在一起，下面按类型分开渲染。
    private var rows: [NoteSummary] {
        app.visibleSummaries()
    }

    private var noteRows: [NoteSummary] {
        rows.filter { !$0.isJournal }
    }

    private var journalRows: [NoteSummary] {
        rows.filter(\.isJournal)
    }

    private var isJournalScope: Bool {
        app.sidebarScope == .journal
    }

    private var scopeTitle: String {
        query.isEmpty ? app.sidebarScope.title : "搜索结果"
    }

    /// 分组标题右边的数量。
    private var headCount: Int {
        if !query.isEmpty { return rows.count }
        return isJournalScope ? app.journalEntries.count : rows.count
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            searchScopePicker

            List(selection: Binding(
                get: { app.selection },
                set: { app.select($0) }
            )) {
                Section {
                    scopeRow(.all, symbol: "tray.full", count: app.noteCount)
                    scopeRow(.orphans, symbol: "circle.dashed", count: app.orphanCount)
                    scopeRow(.journal, symbol: "calendar", count: app.journalEntries.count)
                    ForEach(app.tags) { tag in
                        scopeRow(.tag(tag.name), symbol: "number", count: tag.count)
                    }
                } header: {
                    HStack {
                        Text("视图")
                        Spacer()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                }

                Section {
                    listRows
                } header: {
                    HStack {
                        Text(scopeTitle)
                        Spacer()
                        Text("\(headCount)")
                            .monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 30)

            Divider()
            footer
        }
        .navigationTitle("Silvics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.isShowingNewNote = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("新建笔记 ⌘N")
            }
        }
    }

    // MARK: - 列表内容

    @ViewBuilder
    private var listRows: some View {
        if !query.isEmpty {
            if rows.isEmpty {
                emptyRow
            } else {
                ForEach(noteRows) { note in
                    noteListRow(note)
                }
                ForEach(journalRows) { hit in
                    journalHitRow(hit)
                }
            }
        } else if isJournalScope {
            if app.journalEntries.isEmpty {
                emptyRow
            } else {
                ForEach(app.journalEntries) { entry in
                    journalRow(entry)
                }
            }
        } else if rows.isEmpty {
            emptyRow
        } else {
            ForEach(rows) { note in
                noteListRow(note)
            }
        }
    }

    private func noteListRow(_ note: NoteSummary) -> some View {
        NoteRow(summary: note, isSelected: note.id == app.selection)
            .tag(note.id)
            .contextMenu {
                Button("删除笔记", role: .destructive) {
                    app.deleteNote(id: note.id)
                }
            }
    }

    /// 日记范围：日期 + 星期 + 未完成待办条数。
    private func journalRow(_ entry: JournalEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 9))
                .foregroundStyle(app.selection == entry.id ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text("\(entry.weekday) · 未完成 \(entry.openTodoCount) 条")
                    .font(.system(size: 10.5))
                    .foregroundStyle(entry.openTodoCount == 0 ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .tag(entry.id)
        .contextMenu {
            Button("删除日记", role: .destructive) {
                app.deleteNote(id: entry.id)
            }
        }
    }

    /// 搜索命中里的日记：日期 + 正文片段。
    private func journalHitRow(_ hit: NoteSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
                Text(hit.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
            }
            Text(hit.snippet.isEmpty ? "日记 · 命中正文" : "日记 · \(hit.snippet)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .tag(hit.id)
        .contextMenu {
            Button("删除日记", role: .destructive) {
                app.deleteNote(id: hit.id)
            }
        }
    }

    // MARK: - 范围行

    private func scopeRow(_ scope: SidebarScope, symbol: String, count: Int) -> some View {
        Button {
            app.selectScope(scope)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(app.sidebarScope == scope ? Color.accentColor : Color.secondary)
                Text(scope.title)
                    .font(.system(size: 11.5, weight: app.sidebarScope == scope ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("搜索标题与正文", text: $app.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !app.searchQuery.isEmpty {
                Button {
                    app.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 搜索范围：只搜笔记 / 含日记。默认只搜笔记，和 `⌘P` 一致。
    private var searchScopePicker: some View {
        HStack(spacing: 4) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Button {
                    app.searchScope = scope
                } label: {
                    Text(scope.title)
                        .font(.system(size: 10, weight: app.searchScope == scope ? .medium : .regular))
                        .foregroundStyle(app.searchScope == scope ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(app.searchScope == scope ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("\(app.orphanCount)", systemImage: "circle.dashed")
                .help("孤儿笔记：既无出链也无入链")
            Label("\(app.tags.count)", systemImage: "number")
                .help("标签数量")
            Spacer()
            Label("\(app.noteCount)", systemImage: "square.stack")
                .help("普通笔记数（不含日记）")
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.tertiary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var emptyRow: some View {
        HStack {
            Text(emptyText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var emptyText: String {
        if !query.isEmpty { return "没有命中" }
        if isJournalScope {
            return app.noteCount == 0 && app.journalEntries.isEmpty
                ? "还没有笔记。按 ⌘N 开始，⌘⇧J 打开今天的日记。"
                : "还没有日记。按 ⌘⇧J 打开今天。"
        }
        return app.noteCount == 0 ? "还没有笔记。按 ⌘N 开始。" : "这个范围里没有笔记"
    }
}

// MARK: - 行

private struct NoteRow: View {
    let summary: NoteSummary
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: summary.status.symbolName)
                    .font(.system(size: 9))
                    .foregroundStyle(summary.status == .evergreen ? Color.accentColor : Color.secondary)
                Text(summary.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !summary.snippet.isEmpty {
                Text(summary.snippet)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
