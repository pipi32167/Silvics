import SwiftUI

/// 第二栏：当前模块 + 当前范围的列表。搜索框在顶部。
///
/// 范围切换在 `ModuleNavView`，这里只负责把选中的范围渲染出来。
struct ListPaneView: View {
    @EnvironmentObject private var app: AppState

    private var query: String {
        app.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rows: [NoteSummary] { app.visibleSummaries() }

    private var noteRows: [NoteSummary] {
        rows.filter { NoteTypes.descriptor(for: $0.type).inMainList }
    }

    private var journalRows: [NoteSummary] {
        rows.filter(\.isJournal)
    }

    /// 日记模块列表：今天只留当天，其余按日期倒序。
    private var journalEntries: [JournalEntry] {
        switch app.nav.journalScope {
        case .today:
            let today = JournalDate.today()
            return app.journalEntries.filter { $0.date == today }
        case .all:
            return app.journalEntries
        case .todos, .templates:
            return []
        }
    }

    private var headTitle: String {
        if !query.isEmpty { return "搜索结果" }
        return app.nav.scope.title
    }

    private var headCount: Int {
        switch app.nav.active {
        case .notes: return query.isEmpty ? rows.count : rows.count
        case .journal: return query.isEmpty ? journalEntries.count : rows.count
        case .clips: return app.visibleClips.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: Binding(
                get: { app.selection },
                set: { app.select($0) }
            )) {
                Section {
                    listRows
                } header: {
                    HStack {
                        Text(headTitle)
                        Spacer()
                        Text("\(headCount)").monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 30)
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
        } else if app.nav.active == .clips {
            clipRows
        } else if app.nav.active == .journal {
            journalRowsOrHint
        } else if rows.isEmpty {
            emptyRow
        } else {
            ForEach(rows) { note in
                noteListRow(note)
            }
        }
    }

    @ViewBuilder
    private var clipRows: some View {
        if app.visibleClips.isEmpty {
            emptyRow
        } else {
            ForEach(app.visibleClips) { clip in
                ClipRow(clip: clip, isSelected: app.selection == clip.id)
                    .tag(clip.id)
                    .contextMenu {
                        Button(clip.status == .archived ? "取消归档" : "归档") {
                            app.setClipStatus(
                                id: clip.id,
                                status: clip.status == .archived ? .read : .archived
                            )
                        }
                        Button("删除剪藏", role: .destructive) {
                            app.deleteClip(id: clip.id)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var journalRowsOrHint: some View {
        switch app.nav.journalScope {
        case .todos, .templates:
            hintRow(app.nav.journalScope == .todos ? "待办总览在中栏显示" : "模板在中栏显示")
        default:
            if journalEntries.isEmpty {
                emptyRow
            } else {
                ForEach(journalEntries) { entry in
                    journalRow(entry)
                }
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

    // MARK: - 搜索框

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("搜索\(app.nav.active.title)", text: Binding(
                get: { app.searchQuery },
                set: { app.searchQuery = $0 }
            ))
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

    // MARK: - 空态

    private func hintRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
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
        switch app.nav.active {
        case .clips:
            if app.clipTotalCount == 0 { return "还没有剪藏。按 ⌘⇧V 收一篇。" }
            if case .pending = app.nav.clipScope { return "没有待整理的剪藏。" }
            return "这个范围里没有剪藏"
        case .journal:
            return app.journalEntries.isEmpty
                ? "还没有日记。按 ⌘⇧J 打开今天。"
                : "今天还没有日记。⌘⇧J 建一篇。"
        case .notes:
            if case .tag = app.nav.noteScope, app.noteCount > 0 { return "这个标签下没有笔记" }
            return app.noteCount == 0 ? "还没有笔记。按 ⌘N 开始。" : "这个范围里没有笔记"
        }
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

private struct ClipRow: View {
    let clip: ClipSummary
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(clip.status == .unread ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 5, height: 5)
                Text(clip.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(clip.status == .archived ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if clip.aiState != .done {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help(clip.aiState.label)
                }
            }
            HStack(spacing: 5) {
                if !clip.site.isEmpty {
                    Text(clip.site)
                        .lineLimit(1)
                }
                Text(Self.dateText(clip.createdAt))
                if !clip.tags.isEmpty {
                    Text(clip.tags.prefix(2).joined(separator: " · "))
                        .lineLimit(1)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private static func dateText(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
