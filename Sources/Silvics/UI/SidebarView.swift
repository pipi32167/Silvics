import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var app: AppState

    private var rows: [NoteSummary] {
        app.visibleSummaries()
    }

    private var scopeTitle: String {
        app.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? app.sidebarScope.title
            : "搜索结果"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            List(selection: Binding(
                get: { app.selection },
                set: { app.select($0) }
            )) {
                Section {
                    scopeRow(.all, symbol: "tray.full", count: app.summaries.count)
                    scopeRow(.orphans, symbol: "circle.dashed", count: app.orphanCount)
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
                    if rows.isEmpty {
                        emptyRow
                    } else {
                        ForEach(rows) { note in
                            NoteRow(summary: note, isSelected: note.id == app.selection)
                                .tag(note.id)
                                .contextMenu {
                                    Button("删除笔记", role: .destructive) {
                                        app.deleteNote(id: note.id)
                                    }
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text(scopeTitle)
                        Spacer()
                        Text("\(rows.count)")
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
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("\(app.orphanCount)", systemImage: "circle.dashed")
                .help("孤儿笔记：既无出链也无入链")
            Label("\(app.tags.count)", systemImage: "number")
                .help("标签数量")
            Spacer()
            Label("\(app.summaries.count)", systemImage: "square.stack")
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.tertiary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var emptyRow: some View {
        HStack {
            Text(app.summaries.isEmpty ? "还没有笔记。按 ⌘N 开始。" : "这个范围里没有笔记")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
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
