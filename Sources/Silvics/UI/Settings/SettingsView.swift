import AppKit
import SwiftUI

// MARK: - 标签

enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance
    case clips
    case ai
    case providers
    case sync
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .clips: return "剪藏"
        case .ai: return "AI 提问"
        case .providers: return "模型服务"
        case .sync: return "同步"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "textformat.size"
        case .clips: return "bookmark"
        case .ai: return "sparkles"
        case .providers: return "sparkles"
        case .sync: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

// MARK: - 选中状态

/// 独立窗口里也要能被外部（菜单、状态条）指定打开哪一页。
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .appearance
    private init() {}
}

// MARK: - 版本

private enum AppVersion {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    static var display: String { "版本 \(version)（\(build)）" }
}

// MARK: - 根视图

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var history: [SettingsTab] = [.appearance]
    @State private var historyIndex = 0
    @State private var isHistoryJump = false

    private var activeTab: SettingsTab { navigation.selectedTab ?? .appearance }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(selectedTab: $navigation.selectedTab)
                .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 210)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .tint(Tokens.accent)
        .navigationTitle("设置")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 620, minHeight: 520)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { go(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(historyIndex <= 0)
                .help("后退")

                Button { go(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(historyIndex >= history.count - 1)
                .help("前进")
            }
        }
        .onChange(of: navigation.selectedTab) { _, _ in record() }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch activeTab {
            case .appearance:
                AppearanceSettingsPane()
            case .clips:
                ClipSettingsPane()
            case .ai:
                AISettingsPane()
            case .providers:
                ProvidersSettingsPane()
            case .sync:
                SyncSettingsPane()
            case .about:
                AboutSettingsPane()
            }
        }
        .navigationTitle(activeTab.title)
        .background(Tokens.paper)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 前进后退

    private func go(_ delta: Int) {
        let target = historyIndex + delta
        guard history.indices.contains(target) else { return }
        isHistoryJump = true
        historyIndex = target
        navigation.selectedTab = history[target]
        DispatchQueue.main.async { isHistoryJump = false }
    }

    private func record() {
        guard !isHistoryJump, let tab = navigation.selectedTab else { return }
        guard history.last != tab else { return }
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(tab)
        historyIndex = history.count - 1
    }
}

// MARK: - 侧栏

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab?

    var body: some View {
        // 不用 List(.sidebar)：系统侧栏材质的底色不受我们控制，取 token 自绘才和主窗一致。
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    row(tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)

            Spacer(minLength: 0)

            Text(AppVersion.display)
                .font(.footnote)
                .fontDesign(.monospaced)
                .foregroundStyle(Tokens.ink3)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.rail)
        .navigationTitle("设置")
    }

    private func row(_ tab: SettingsTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Tokens.accent : Tokens.ink3)
                Text(tab.title)
                    .font(.system(size: Tokens.TypeScale.body.size))
                    .foregroundStyle(selected ? Tokens.accent : Tokens.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                    .fill(selected ? Tokens.selectedFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - macOS 26 可用性

extension View {
    /// 滚动边缘的渐进模糊，只有 macOS 26 有。
    @ViewBuilder
    func scrollEdgeEffectSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
