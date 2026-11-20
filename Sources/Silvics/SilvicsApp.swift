import SwiftUI

@main
struct SilvicsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { appDelegate.app = app }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建笔记") {
                    app.isShowingNewNote = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("立即保存") {
                    app.flushPendingSave()
                }
                .keyboardShortcut("s", modifiers: .command)

                Divider()

                Button("重建全部索引") {
                    app.rebuildIndexes()
                }
            }
        }
    }
}

/// 负责在失焦与退出时把未落库的正文刷进数据库。
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            app?.flushPendingSave()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            app?.flushPendingSave()
        }
    }
}
