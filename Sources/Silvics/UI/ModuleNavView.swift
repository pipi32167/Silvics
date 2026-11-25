import SwiftUI

/// 第一栏：模块导航 + 当前模块的二级导航。
///
/// 设置是独立窗口，不在这里。
struct ModuleNavView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        List {
            Section {
                ForEach(AppModule.allCases) { module in
                    moduleRow(module)
                }
            } header: {
                sectionHeader("模块")
            }

            Section {
                ForEach(scopes, id: \.title) { row in
                    scopeRow(row)
                }
            } header: {
                sectionHeader("范围")
            }

            if !tagRows.isEmpty {
                Section {
                    ForEach(tagRows, id: \.self) { tag in
                        scopeRow(ScopeRow(
                            title: "#\(tag.name)",
                            symbol: "number",
                            count: tag.count,
                            scope: navScope(for: tag.name)
                        ))
                    }
                } header: {
                    sectionHeader("标签")
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 30)
        .navigationTitle("Silvics")
    }

    // MARK: - 行

    private func moduleRow(_ module: AppModule) -> some View {
        let active = app.nav.active == module
        return Button {
            app.selectModule(module)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: module.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                Text(module.title)
                    .font(.system(size: 11.5, weight: active ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(moduleCount(module))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    private func scopeRow(_ row: ScopeRow) -> some View {
        let active = app.nav.scope == row.scope
        return Button {
            app.applyScope(row.scope)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: row.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                Text(row.title)
                    .font(.system(size: 11.5, weight: active ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(row.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
    }

    // MARK: - 数据

    private struct ScopeRow {
        let title: String
        let symbol: String
        let count: Int
        let scope: ModuleScope
    }

    private var scopes: [ScopeRow] {
        switch app.nav.active {
        case .notes:
            return [
                ScopeRow(title: "全部", symbol: "tray.full", count: app.noteCount, scope: .note(.all)),
                ScopeRow(title: "孤儿笔记", symbol: "circle.dashed", count: app.orphanCount, scope: .note(.orphans)),
            ]
        case .journal:
            return [
                ScopeRow(title: "今天", symbol: "sun.max", count: todayCount, scope: .journal(.today)),
                ScopeRow(title: "全部日记", symbol: "calendar", count: app.journalEntries.count, scope: .journal(.all)),
                ScopeRow(title: "待办总览", symbol: "checklist", count: app.journalOpenTodoCount, scope: .journal(.todos)),
                ScopeRow(title: "模板", symbol: "doc.text", count: app.journalTemplateCount, scope: .journal(.templates)),
            ]
        case .clips:
            return [
                ScopeRow(title: "未读", symbol: "bookmark", count: app.clipUnreadCount, scope: .clip(.unread)),
                ScopeRow(title: "全部", symbol: "books.vertical", count: app.clipTotalCount, scope: .clip(.all)),
                ScopeRow(title: "已归档", symbol: "archivebox", count: app.clipArchivedCount, scope: .clip(.archived)),
                ScopeRow(title: "待整理", symbol: "sparkles", count: app.clipPendingCount, scope: .clip(.pending)),
            ]
        }
    }

    private var tagRows: [TagCount] {
        switch app.nav.active {
        case .notes: return app.tags
        case .clips: return app.clipTags
        case .journal: return []
        }
    }

    private func navScope(for tag: String) -> ModuleScope {
        app.nav.active == .clips ? .clip(.tag(tag)) : .note(.tag(tag))
    }

    private var todayCount: Int {
        let today = JournalDate.today()
        return app.journalEntries.contains { $0.date == today } ? 1 : 0
    }

    private func moduleCount(_ module: AppModule) -> Int {
        switch module {
        case .notes: return app.noteCount
        case .journal: return app.journalEntries.count
        case .clips: return app.clipTotalCount
        }
    }
}
