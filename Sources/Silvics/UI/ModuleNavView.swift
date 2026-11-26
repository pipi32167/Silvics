import SwiftUI

/// 第一栏：模块导航 + 当前模块的二级导航。
///
/// 收起后只留一列图标，范围与标签藏起来，把宽度让给内容。
/// 设置是独立窗口，不在这里。
struct ModuleNavView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if app.isNavCollapsed {
                iconRail
            } else {
                fullList
            }
        }
        .navigationTitle("Silvics")
    }

    // MARK: - 收起后的一列图标

    private var iconRail: some View {
        VStack(spacing: 8) {
            ForEach(AppModule.allCases) { module in
                Button {
                    app.selectModule(module)
                } label: {
                    Text(module.icon)
                        .font(.system(size: 15))
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(app.nav.active == module ? Tokens.selectedFill : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(
                                    app.nav.active == module ? Tokens.accent.opacity(0.5) : Color.clear,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("\(module.title)（\(module.shortcutLabel)）")
            }

            Button {
                app.toggleNavPane()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .symbolRenderingMode(.monochrome)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("展开模块栏 ⌘⌥S")

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 展开态

    private var fullList: some View {
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
        .scrollContentBackground(.hidden)
        .background(Tokens.rail)
        .environment(\.defaultMinListRowHeight, 30)
    }

    // MARK: - 行

    private func moduleRow(_ module: AppModule) -> some View {
        let active = app.nav.active == module
        return Button {
            app.selectModule(module)
        } label: {
            HStack(spacing: 6) {
                Text(module.icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(module.title)
                    .font(.system(size: 11.5, weight: active ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    // 标题优先占位：模块栏压到 132 px 时先保住标题，不先退化成省略号。
                    .layoutPriority(1)
                Spacer(minLength: 2)
                // 条数与快捷键当成一个不压缩的尾巴，中间留 6 px，避免读成「22⌘1」。
                HStack(spacing: 6) {
                    Text("\(moduleCount(module))")
                        .foregroundStyle(.tertiary)
                    Text(module.shortcutLabel)
                        .foregroundStyle(active ? Tokens.accent : Tokens.ink3)
                        .accessibilityIdentifier("module-shortcut-\(module.rawValue)")
                }
                .font(.system(size: 10).monospacedDigit())
                .fixedSize()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .background(selectionBackground(active))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    /// 选中行的底色。模块行与范围行共用，收起态的图标栏也用同一套色阶。
    private func selectionBackground(_ active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(active ? Tokens.selectedFill : Color.clear)
    }

    private func scopeRow(_ row: ScopeRow) -> some View {
        let active = app.nav.scope == row.scope
        return Button {
            app.applyScope(row.scope)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: row.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? Tokens.accent : Tokens.ink2)
                Text(row.title)
                    .font(.system(size: 11.5, weight: active ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(row.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(selectionBackground(active))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Tokens.TypeScale.meta.size, weight: .medium))
            .foregroundStyle(Tokens.ink3)
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
