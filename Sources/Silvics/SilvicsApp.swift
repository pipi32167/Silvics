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
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    SettingsWindowController.show(app: app)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("新建笔记") {
                    app.isShowingNewNote = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("打开笔记…") {
                    app.isShowingQuickOpen = true
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("孤儿笔记") {
                    app.selectScope(.orphans)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("立即保存") {
                    app.flushPendingSave()
                }
                .keyboardShortcut("s", modifiers: .command)

                Divider()

                Button("重命名笔记…") {
                    app.isShowingRenameSheet = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.current == nil)

                Button("编辑别名…") {
                    app.isShowingAliasSheet = true
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(app.current == nil)

                Divider()

                Button("整理未链接提及…") {
                    app.refreshMentionGroups()
                    app.isShowingMentionsSheet = true
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("处理同步冲突…") {
                    app.isShowingConflicts = true
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(app.syncConflicts.isEmpty)

                Button("撤销上次批量转换") {
                    app.undoLastConversion()
                }
                .disabled(!app.canUndoConversion)

                Divider()

                Button("重建全部索引") {
                    app.rebuildIndexes()
                }

                Divider()

                Button("备份与同步…") {
                    app.isShowingSyncSheet = true
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("立即同步") {
                    app.performSyncWork({ try [$0.sync().summary] }, done: { _ in })
                }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(app.isSyncing)
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
