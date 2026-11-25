import SwiftUI

@main
struct SilvicsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()

    init() {
        #if DEBUG
        // 仅 DEBUG：`SILVICS_INVERT_DRILL=<dir>` 跑保存链路倒转的两次启动演练，跑完就退出。
        InvertDrill.runIfRequested()
        // 仅 DEBUG：`SILVICS_VAULT_SWITCH_DRILL=<dir>` 跑「换 vault 目录 + 删库重建」的三次启动演练。
        VaultSwitchDrill.runIfRequested()
        // 仅 DEBUG：`SILVICS_JOURNAL_DRILL=<dir>` 跑「模板 + 承接 + journal/ 落盘」的命令行演练。
        JournalDrill.runIfRequested()
        // 离屏截图：`@NSApplicationDelegateAdaptor` 的 `applicationDidFinishLaunching`
        // 在「一个可见窗口都没有」的会话里实测不触发，所以入口放在 init，投一次主队列。
        if OffscreenCapture.isRequested {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { OffscreenCapture.startIfRequested() }
            }
        }
        #endif
    }

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

                Button("新建剪藏…") {
                    app.isShowingNewClip = true
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Button(app.isListPaneVisible ? "隐藏列表栏" : "显示列表栏") {
                    app.toggleListPane()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Divider()

                Button("打开笔记…") {
                    app.isShowingQuickOpen = true
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("孤儿笔记") {
                    app.selectScope(.orphans)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("剪藏（未读）") {
                    app.selectClipScope(.clipUnread)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("今天的日记") {
                    app.goToToday()
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])

                Button("待办总览…") {
                    app.openTodoOverview()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("插入承接（当前行之前）") {
                    app.insertCarryAtCaret()
                }
                .disabled(app.current?.type != NoteTypes.journalID)

                Button("日记模板…") {
                    app.isShowingJournalTemplateSheet = true
                }

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
                    SettingsWindowController.show(app: app, tab: .sync)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("立即同步") {
                    app.syncNow()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // 离屏通道：App 起来但一个可见窗口都没有时，窗口截图与 `onAppear` 钩子全都失效。
        // 入口放在这里，因为它不依赖任何窗口被创建。
        MainActor.assumeIsolated { OffscreenCapture.startIfRequested() }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            app?.flushPendingSave()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            app?.flushPendingSave()
            app?.syncOnResignActiveIfDue()
        }
    }
}
