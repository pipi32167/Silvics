import SwiftUI

/// 第一栏：模块导航。三行，切四栏的内容。
///
/// 设置是独立窗口，不在这里。
struct ModuleNavView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        List(selection: Binding(
            get: { app.nav.active },
            set: { module in
                guard let module else { return }
                app.selectModule(module)
            }
        )) {
            Section {
                ForEach(AppModule.allCases) { module in
                    moduleRow(module)
                        .tag(module)
                }
            } header: {
                Text("模块")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 30)
        .navigationTitle("Silvics")
    }

    private func moduleRow(_ module: AppModule) -> some View {
        let active = app.nav.active == module
        return HStack(spacing: 6) {
            Image(systemName: module.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
            Text(module.title)
                .font(.system(size: 11.5, weight: active ? .medium : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count(for: module))")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func count(for module: AppModule) -> Int {
        switch module {
        case .notes: return app.noteCount
        case .journal: return app.journalEntries.count
        case .clips: return app.clipTotalCount
        }
    }
}
