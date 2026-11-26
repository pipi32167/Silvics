#if DEBUG
import AppKit
import Carbon
import SwiftUI

/// 仅 DEBUG：把窗口自己画成 PNG，用于验收取证。
///
/// 为什么不用 `screencapture`：它要「屏幕录制」授权，而授权只能人工在系统设置里给。
/// `cacheDisplay` 是 App 画自己的视图，不需要任何授权，也不受窗口遮挡影响。
///
/// 两个环境变量：
/// - `SILVICS_CAPTURE=/tmp/reports/x.png`：图片路径前缀。有多个可见窗口时追加 `-1`、`-2`。
/// - `SILVICS_SHOW=quickopen|mentions|alias|rename|templates|templates-result`：启动后直接打开对应面板，便于截取。
/// - `SILVICS_CARET=<文本>`：把光标放到含该文本的段落（验收「光标行露源码」必须能指定光标）。
enum DebugCapture {

    static var path: String? {
        ProcessInfo.processInfo.environment["SILVICS_CAPTURE"]
    }

    static var showPanel: String? {
        ProcessInfo.processInfo.environment["SILVICS_SHOW"]
    }

    /// 需要真实窗口才能挂 sheet 的面板开关。离屏通道（`SILVICS_OFFSCREEN`）跳过这些。
    static let sheetPanels: Set<String> = [
        "quickopen", "mentions", "mentions-preview", "todos", "todo-overview", "todo-jump",
        "settings", "settings-providers", "settings-providers-demo", "settings-about",
        "sync", "journal-templates", "journal-template", "templates", "templates-result",
        "alias", "rename",
    ]

    /// 启动时按环境变量打开面板。
    ///
    /// `offscreen` 为 true 时走离屏通道：sheet 类面板没有窗口挂不住，跳过并写日志。
    @MainActor
    static func applyShowFlag(_ app: AppState, offscreen: Bool = false) {
        // `SILVICS_DARK=1`：取证时切深色外观，用于「同一篇的深浅色对比」。
        if ProcessInfo.processInfo.environment["SILVICS_DARK"] == "1" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // `SILVICS_WINDOW=1360x1560`：取证时把窗口撑到足够装下整篇（内容更高也不截断）。
        // 延迟再设一次：SwiftUI 在 onAppear 之后还会按初始尺寸重新布局一遍。
        if let raw = ProcessInfo.processInfo.environment["SILVICS_WINDOW"] {
            let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                let size = NSSize(width: parts[0], height: parts[1])
                func resize() {
                    guard let window = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
                    window.setContentSize(size)
                }
                resize()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: resize)
            }
        }
        // SILVICS_APPEARANCE="body=18,code=14,spacing=7,panel=16,family=serif"：取证时预置外观。
        if let raw = ProcessInfo.processInfo.environment["SILVICS_APPEARANCE"] {
            var settings = app.appearance
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=").map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "body": settings.bodySize = Double(parts[1]) ?? settings.bodySize
                case "code": settings.codeSize = Double(parts[1]) ?? settings.codeSize
                case "spacing": settings.lineSpacing = Double(parts[1]) ?? settings.lineSpacing
                case "panel": settings.panelSize = Double(parts[1]) ?? settings.panelSize
                case "family": settings.fontFamily = AppearanceSettings.FontFamily(rawValue: parts[1]) ?? settings.fontFamily
                default: break
                }
            }
            app.updateAppearance(settings)
        }

        // `SILVICS_JOURNAL_MENTIONS=1|0`：取证时切换日记提及开关（对比图用）。
        if let raw = ProcessInfo.processInfo.environment["SILVICS_JOURNAL_MENTIONS"] {
            app.setJournalScanMentions(raw == "1")
        }
        if let keyword = ProcessInfo.processInfo.environment["SILVICS_SELECT"],
           let match = app.summaries.first(where: { $0.title.contains(keyword) }) {
            // 演示数据最后停在日记上，先切回笔记模块的「全部」，否则选中的笔记不在列表里。
            app.selectModule(.notes)
            app.applyScope(.note(.all))
            app.select(match.id)
        }
        // 先切 vault 再播种 / 开面板：`SILVICS_VAULT` 换目录后，后面的写入要落到新目录。
        applySyncFlags(app)

        // `SILVICS_AI_PROVIDER=1`：预置一个假的对话服务商并绑到「对话」用途。
        // 只影响界面状态（输入框可发送），不会真的发请求。
        if ProcessInfo.processInfo.environment["SILVICS_AI_PROVIDER"] == "1" {
            seedDemoProvider(app)
        }

        // `SILVICS_JOURNAL_CARRY=<关键字>`：取证「承接插在当前行之前」。
        // 先备好上一篇日记与今天的正文（同步），等编辑区出来后把光标放进含关键字的段落，
        // 再走 `insertCarryAtCaret` 的真实链路。截图里要能看出承接段不在最前。
        if let keyword = ProcessInfo.processInfo.environment["SILVICS_JOURNAL_CARRY"], !keyword.isEmpty {
            seedCarryDemo(app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                guard app.debugPlaceCaret(atKeyword: keyword) else {
                    print("[carry-demo] 编辑区里找不到「\(keyword)」")
                    return
                }
                print("[carry-demo] 插入前光标在含「\(keyword)」的段落，结果：\(app.insertCarryAtCaret())")
            }
        }

        // 离屏通道没有窗口可挂 sheet：面板类钩子跳过，其余（日记、列表、表格演示）照旧。
        if offscreen, let showPanel, sheetPanels.contains(showPanel) {
            OffscreenCapture.log("SILVICS_SHOW=\(showPanel) 需要窗口挂 sheet，离屏通道跳过（只渲染主界面）")
        } else {
            applyPanelFlag(app, panel: showPanel)
        }

        // `SILVICS_NAV_COLLAPSED=1`：取证时把模块栏收成一列图标。
        if ProcessInfo.processInfo.environment["SILVICS_NAV_COLLAPSED"] == "1", !app.isNavCollapsed {
            app.toggleNavPane()
        }

        // `SILVICS_LIST_WIDTH=300`：取证时把列表栏拉到指定宽度。
        if let raw = ProcessInfo.processInfo.environment["SILVICS_LIST_WIDTH"], let width = Double(raw) {
            app.setListPaneWidth(CGFloat(width))
        }

        // `SILVICS_SEARCH=<词>`：取证时在当前模块里预置搜索。
        // 必须放在范围切换之后：换范围会清空搜索词。
        if let q = ProcessInfo.processInfo.environment["SILVICS_SEARCH"], !q.isEmpty {
            app.searchQuery = q
        }

        // 取证时先把状态条清掉，截图里不出现「已从 vault 重建…」这类启动提示。
        if path != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { app.clearStatus() }
        }
    }

    /// `SILVICS_SHOW` 的实际动作。抽出来是为了让离屏通道能整块跳过 sheet 类面板。
    @MainActor
    private static func applyPanelFlag(_ app: AppState, panel: String?) {
        switch panel {
            case "quickopen": app.isShowingQuickOpen = true
            case "mentions", "mentions-preview":
                app.refreshMentionGroups()
                app.isShowingMentionsSheet = true
            case "todos", "todo-overview": app.openTodoOverview()
            case "todo-jump":
                // 取证用：打开总览并按文本跳转，走的是面板里点击的同一路径。
                app.openTodoOverview()
                if let text = ProcessInfo.processInfo.environment["SILVICS_TODO_TEXT"],
                   let todo = app.todoOverview.first(where: { $0.text.contains(text) }) {
                    app.jumpToTodo(todo)
                }
            case "list-collapsed": if app.isListPaneVisible { app.toggleListPane() }
            case "list-expanded": if !app.isListPaneVisible { app.toggleListPane() }
            case "module-notes": app.selectModule(.notes)
            case "module-journal": app.selectModule(.journal)
            case "module-clips": app.selectModule(.clips)
            case "journal": app.selectModule(.journal); app.applyScope(.journal(.all))
            case "clips", "clip-unread": app.selectModule(.clips); app.applyScope(.clip(.unread))
            case "clips-demo":
                seedClipsDemo(app)
                app.selectModule(.clips)
                app.applyScope(.clip(.unread))
            case "clips-all": app.selectModule(.clips); app.applyScope(.clip(.all))
            case "clips-archived": app.selectModule(.clips); app.applyScope(.clip(.archived))
            case "clips-pending": app.selectModule(.clips); app.applyScope(.clip(.pending))
            case "journal-todos", "journal-todo": app.selectModule(.journal); app.applyScope(.journal(.todos))
            case "journal-templates-nav": app.selectModule(.journal); app.applyScope(.journal(.templates))
            case "note-tag":
                if let tag = ProcessInfo.processInfo.environment["SILVICS_NOTE_TAG"], !tag.isEmpty {
                    app.selectModule(.notes); app.applyScope(.note(.tag(tag)))
                }
            case "clip-tag":
                if let tag = ProcessInfo.processInfo.environment["SILVICS_CLIP_TAG"], !tag.isEmpty {
                    app.selectModule(.clips); app.applyScope(.clip(.tag(tag)))
                }
            case "clip-pdf": importPDFClips(app)
            case "new-clip": app.selectModule(.clips); app.applyScope(.clip(.unread)); app.isShowingNewClip = true
            case "settings-clips": SettingsWindowController.show(app: app, tab: .clips)
            case "lists", "lists-demo": seedListsDemo(app)
            case "indent", "indent-demo": seedIndentDemo(app)
            case "tables", "tables-demo": seedTablesDemo(app)
            case "journal-today": app.goToToday()
            case "settings":
                SettingsWindowController.show(app: app, tab: .appearance)
            case "settings-providers-demo":
                seedDemoProvider(app)
                SettingsWindowController.show(app: app, tab: .providers)
            case "settings-providers":
                SettingsWindowController.show(app: app, tab: .providers)
            case "settings-about":
                SettingsWindowController.show(app: app, tab: .about)
            case "journal-templates", "journal-template", "templates":
                seedDemoTemplates(app)
                app.selectModule(.journal)
                app.applyScope(.journal(.templates))
            case "templates-result":
                // 取证：先落盘 3 份演示模板，再用面板保存时的同一个 `saveJournalTemplate` 新建一份，
                // 然后走 `⌘⇧J` 的同一条链路建今天这篇，截的是真实保存 + 真实新建的结果。
                seedDemoTemplates(app)
                _ = try? app.saveJournalTemplate(
                    nil,
                    name: "早间",
                    order: "4",
                    body: "- [ ] 写今天的三件事\n- [ ] 读 15 分钟"
                )
                app.setJournalTemplateNames(["工作", "生活"])
                app.goToToday()
            case "alias": app.isShowingAliasSheet = true        case "rename": app.isShowingRenameSheet = true
            case "sync": SettingsWindowController.show(app: app, tab: .sync)
            case "ai", "ai-empty":
                app.setAIPanel(.ai)
            case "ai-details", "details":
                app.setAIPanel(.details)
            case "ai-chat":
                seedAIConversation(app)
                app.setAIPanel(.ai)
            case "ai-quote":
                app.setAIPanel(.ai)
                app.aiQuote = AIQuote(
                    noteID: app.current?.id ?? "n-demo",
                    noteTitle: app.current?.title ?? "剪藏标题",
                    text: "稀疏重复优于集中突击：同样的总时长拆成多次，每次之间留出遗忘，回忆本身就在加固记忆。"
                )
            case "ai-sending":
                seedAIConversation(app)
                app.setAIPanel(.ai)
                app.aiIsSending = true
            case "ai-error":
                seedAIConversation(app)
                app.setAIPanel(.ai)
                app.aiError = "模型响应超时"
            case "ai-evidence":
                app.setAIPanel(.ai)
                app.aiEvidences = [
                    AIEvidence(
                        url: "https://example.com/spaced-repetition",
                        title: "间隔重复的实验证据",
                        text: "实验组把 60 分钟拆成 6 次，每次 10 分钟，一周后测试回忆率显著高于一次学完的对照组。"
                    )
                ]
            case "ai-no-provider":
                app.setAIPanel(.ai)
                app.aiError = "还没有可用的对话模型：未选择服务商"
            case "settings-ai":
                SettingsWindowController.show(app: app, tab: .ai)
            default: break
            }
    }

    /// 仅取证：往当前会话写一组固定的提问与回答。
    ///
    /// 不调模型：截图要的是布局，不是真实回答。
    @MainActor
    private static func seedAIConversation(_ app: AppState) {
        let noteID = app.aiSessionID
        let store = app.aiStore
        let base = AIMessage.now() - 60_000
        let quote = AIQuote(
            noteID: app.current?.id ?? "n-demo",
            noteTitle: app.current?.title ?? "剪藏标题",
            text: "稀疏重复优于集中突击：同样的总时长拆成多次，每次之间留出遗忘。"
        )
        let messages: [AIMessage] = [
            AIMessage(
                id: "demo-1", at: base, role: AIMessage.roleUser,
                content: "这篇说的「间隔」到底该多长？", quote: quote
            ),
            AIMessage(
                id: "demo-2", at: base + 3_000, role: AIMessage.roleAssistant,
                content: "文中给的是「刚好开始遗忘时」而不是固定天数。实践上先用 1 天、3 天、7 天三档，之后按回忆难度拉开。关键不是日历，是每次回忆都得有点费力。",
                model: "deepseek-chat"
            ),
            AIMessage(
                id: "demo-3", at: base + 8_000, role: AIMessage.roleUser,
                content: "那和集中复习比，总时长一样的话哪个更好？"
            ),
            AIMessage(
                id: "demo-4", at: base + 12_000, role: AIMessage.roleAssistant,
                content: "总时长相同时间隔更好。原因有两条：一是每次回忆都是一次检索练习，二是间隔让遗忘发生，重新提取的难度更高，留下的痕迹更深。集中复习的收益主要停在当时的熟悉感上。",
                model: "deepseek-chat"
            ),
        ]
        _ = try? store.save(messages, noteID: noteID)
        app.reloadAIConversation()
    }

    /// 仅取证：备好「上一篇日记 + 今天日记」，供 `SILVICS_JOURNAL_CARRY` 演示中间插入。
    ///
    /// 今天的正文固定 6 行，`## 生活` 在第 4 行（1-based），承接段插在它之前。
    @MainActor
    private static func seedCarryDemo(_ app: AppState) {
        let today = JournalDate.today()
        let previous = JournalDate.offset(today, by: -1)
        app.debugSeedJournal(on: previous, body: """
        ## 工作
        - [ ] 把保存链路倒过来
        - [x] 补类型注册表
        ## 生活
        - [ ] 跑步 20 分钟
        """)
        app.debugSeedJournal(on: today, body: """
        ## 工作
        - [ ] 写批次 6 的测试
        - [ ] 把日记接到界面上
        ## 生活
        - [ ] 买咖啡豆
        今天重读 稀疏重复优于集中突击 的论证，集中突击只能短期见效。
        """)
        _ = app.openJournal(on: today, using: [])
    }

    /// 仅取证：`SILVICS_SHOW=clip-pdf` + `SILVICS_CLIP_FILE=<pdf>[:<pdf>…]`。
    /// 走真实的 `ClipIngest` 与 `saveClip`，用来截「PDF 剪藏存进去后读起来什么样」。
    /// 两个入口（`RootView.onAppear` 与离屏通道）都会调 `applyShowFlag`，导入只能跑一次，
    /// 否则同一份 PDF 会落两份。
    nonisolated(unsafe) private static var didImportPDF = false

    @MainActor
    private static func importPDFClips(_ app: AppState) {
        guard !didImportPDF else { return }
        didImportPDF = true
        let raw = ProcessInfo.processInfo.environment["SILVICS_CLIP_FILE"] ?? ""
        for path in raw.split(separator: ":").map(String.init) where !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            do {
                let outcome = try ClipIngest.outcome(fromFile: url)
                if app.existingClip(forBody: outcome.draft.body) != nil {
                    print("[clip-pdf] 跳过重复：\(url.lastPathComponent)")
                    continue
                }
                _ = try app.saveClip(outcome.draft)
                print("[clip-pdf] 已导入 \(url.lastPathComponent)：\(outcome.draft.body.count) 字\(outcome.warnings.joined(separator: " / "))")
            } catch {
                print("[clip-pdf] 导入失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        app.selectModule(.clips)
        app.applyScope(.clip(.all))
    }

    /// 仅取证：三篇剪藏，覆盖未读 / 已读 / 待整理三种状态。
    ///
    /// 剪藏的列表、右栏摘要、底部新建行都要有真实条目才看得出版式。
    @MainActor
    private static func seedClipsDemo(_ app: AppState) {
        guard app.clipTotalCount == 0 else { return }
        let demos: [(title: String, site: String, summary: String, tags: [String], status: ClipStatus, aiState: ClipAIState)] = [
            (
                "稀疏重复优于集中突击",
                "少数派",
                "同样的总时长拆成多次，每次之间留出遗忘，回忆本身就在加固记忆。集中突击只在短周期里占优。",
                ["记忆", "学习方法"],
                .unread,
                .done
            ),
            (
                "为什么清单比目标更管用",
                "Matrix",
                "目标描述终态，清单描述下一个动作。终态无法直接执行，动作可以。",
                ["行动"],
                .read,
                .done
            ),
            (
                "笔记的维护成本决定它会不会死",
                "个人博客",
                "整理成本高于写作收益时，笔记系统会在三个月内停摆。降低维护成本比提升容量更重要。",
                ["笔记方法"],
                .unread,
                .pending
            ),
        ]
        for demo in demos {
            let draft = ClipDraft(
                url: "https://example.com/\(demo.title)",
                title: demo.title,
                site: demo.site,
                body: demo.summary + "\n\n" + String(repeating: "这是正文段落，用来撑出剪藏阅读视图的高度。\n\n", count: 6),
                summary: demo.summary,
                tags: demo.tags,
                status: demo.status,
                aiState: demo.aiState
            )
            _ = try? app.saveClip(draft)
        }
        app.selectModule(.notes)
    }

    /// 仅取证：`SILVICS_SHOW=lists` 建两篇列表演示笔记并选中其中一篇。
    ///
    /// - 「列表渲染演示」：无序 / 有序 / 引用同一篇，用来验符号、序号、软换行对齐（截图 1、3）。
    /// - 「待办渲染演示」：只有待办行，一条已完成一条未完成，用来验复选框浮层（截图 2）。
    ///
    /// `SILVICS_SELECT` 在这一步之后才跑（顺序见 `applyShowFlag`），所以选哪篇由它决定。
    @MainActor
    private static func seedListsDemo(_ app: AppState) {
        let demos: [(title: String, body: String)] = [
            ("列表渲染演示", """
            ## 无序
            - 列表标记压宽到 ≈ 0，正文从缩进处开始
            - 软换行之后第二行的左缘要与首行正文对齐，所以这一条故意写得很长，长到一定会换行，用来检查对齐
            - 第三条

            ## 有序
            1. 先跑 XCTest
            2. 再跑截图
            10. 序号用原文，不重排

            > 引用里的 `>` 也压宽，左侧留一条竖线
            结束行，光标停在这里看其他行的渲染态。
            """),
            ("待办渲染演示", """
            ## 待办
            - [x] 列表标记压宽到 ≈ 0
            - [ ] 待办复选框改成浮层
            - [ ] 光标行露源码，其余行渲染

            光标停在最后一行，三条待办都保持渲染态。
            """),
        ]

        var createdCount = 0
        for demo in demos {
            if let existing = app.summaries.first(where: { $0.title == demo.title }) {
                app.select(existing.id)
                app.bodyDidChange(demo.body)
                app.flushPendingSave()
                createdCount += 1
                continue
            }
            guard let note = app.createNote(title: demo.title) else { continue }
            app.bodyDidChange(demo.body)
            app.flushPendingSave()
            app.select(note.id)
            createdCount += 1
        }
        if createdCount == 0 { print("[Silvics] 列表演示笔记没有建出来") }

        // `SILVICS_SELECT` 在 `applyShowFlag` 里跑得比这里早（那时笔记还不存在），
        // 所以这里再按同一个关键字选一次，截图才能指定截哪篇。
        if let keyword = ProcessInfo.processInfo.environment["SILVICS_SELECT"],
           let match = app.summaries.first(where: { $0.title.contains(keyword) }) {
            app.selectModule(.notes)
            app.applyScope(.note(.all))
            app.select(match.id)
        }
    }

    /// 仅取证：`SILVICS_SHOW=indent` 建一篇「行首缩进」演示笔记（issue #41）。
    ///
    /// 一篇里放齐五类带行首空白的块级标记：无序 / 有序 / 待办 / 引用 / 标题，另加一个 tab 缩进项。
    /// 配合 `SILVICS_CARET=<关键字>` 把光标放进其中一行，截「编辑态是否还留着行首空白」；
    /// 光标放在收尾行就是渲染态对照。
    @MainActor
    private static func seedIndentDemo(_ app: AppState) {
        let title = "缩进行编辑态演示"
        let body = """
        ## 锻炼
        - [x] 跑步：3.2k × 2 + 1.2k + 2k 组休 2min

        ## 日记
        - 开始做自用的常青笔记 Silvics
          - 晚上去内道跑步，最后一组跟了 C 组，2k 跑得累死。
          1. 有序缩进两格
        \t- tab 缩进一项

        ## 待办
        - [ ] 顶层待办
          - [ ] 缩进两格待办

        ## 引用
        > 顶层引用
          > 缩进两格引用

        ## 标题
          ## 缩进两格标题

        ## 收尾
        光标停在这一行，上面都保持渲染态。
        """

        if let existing = app.summaries.first(where: { $0.title == title }) {
            app.select(existing.id)
        } else if let note = app.createNote(title: title) {
            app.select(note.id)
        } else {
            print("[Silvics] 缩进演示笔记没有建出来")
            return
        }
        app.bodyDidChange(body)
        app.flushPendingSave()

        if let keyword = ProcessInfo.processInfo.environment["SILVICS_SELECT"],
           let match = app.summaries.first(where: { $0.title.contains(keyword) }) {
            app.selectModule(.notes)
            app.applyScope(.note(.all))
            app.select(match.id)
        }
    }

    /// 仅取证：`SILVICS_SHOW=tables` 建两篇表格演示笔记。
    ///
    /// 第一篇里放两个一模一样的表：上面一块是渲染态，下面一块在围栏代码块里（不识别），
    /// 并排就能看出「渲染」与「原始 pipe」的差别。第二篇是 4 列表格，用来验多列。
    @MainActor
    private static func seedTablesDemo(_ app: AppState) {
        let demos: [(title: String, body: String)] = [
            ("表格渲染演示", """
            ## 三列表格

            | 项目 | 状态 | 备注 |
            | --- | :---: | --- |
            | 排版 | 未实现 | 三列 |
            | 对齐 | 待验证 | 等宽 |

            上面这块是渲染态：表头加粗、下面一条淡线、pipe 按显示宽度对齐。
            光标停在下面这些普通段落时，上面四行保持对齐。

            ## 原始 pipe（代码块里不识别）

            ```text
            | 项目 | 状态 | 备注 |
            | --- | --- | --- |
            | 排版 | 未实现 | 三列 |
            | 对齐 | 待验证 | 等宽 |
            ```
            """),
            ("表格四列演示", """
            | 类型 | 数据 | 位置 | 备注 |
            | --- | --- | --- | --- |
            | 笔记 | 纯文本 | vault/notes | 唯一真相 |
            | 索引 | sqlite | 可重建 | 从正文重算 |
            | 引用 | 双链 | 悬空可恢复 | 后建目标能接上 |

            光标停在这一行时，上面五行仍然保持渲染态。
            """),
        ]

        for demo in demos {
            if let existing = app.summaries.first(where: { $0.title == demo.title }) {
                app.select(existing.id)
                app.bodyDidChange(demo.body)
                app.flushPendingSave()
                continue
            }
            guard let note = app.createNote(title: demo.title) else { continue }
            app.bodyDidChange(demo.body)
            app.flushPendingSave()
            app.select(note.id)
        }

        if let keyword = ProcessInfo.processInfo.environment["SILVICS_SELECT"],
           let match = app.summaries.first(where: { $0.title.contains(keyword) }) {
            app.selectModule(.notes)
            app.applyScope(.note(.all))
            app.select(match.id)
        }
    }

    /// 仅取证：`SILVICS_TEMPLATES=1` 往 vault 的 `templates/` 写三份演示模板（order 1/2/3）。
    /// `SILVICS_TEMPLATE_MEMORY=工作,复盘` 再预置记忆，便于截到「部分勾选」的状态。
    ///
    /// 走的是面板保存时的同一个 `JournalTemplates.create`，所以截出来的文件格式就是 App 写出来的格式。
    @MainActor
    private static func seedDemoTemplates(_ app: AppState) {
        let env = ProcessInfo.processInfo.environment
        if env["SILVICS_TEMPLATES"] == "1" {
            let demo: [(name: String, order: String, body: String)] = [
                ("工作", "1", "- [ ] 写批次 7 的模板测试\n- [ ] 更新 docs/笔记类型与元数据.md"),
                ("生活", "2", "- [ ] 跑步 20 分钟\n- [ ] 买咖啡豆"),
                ("复盘", "3", "今天做完的三件事；明天只留一件。"),
            ]
            for item in demo {
                do {
                    try JournalTemplates.create(
                        name: item.name,
                        order: item.order,
                        body: item.body,
                        in: app.vaultURL
                    )
                } catch {
                    // 重跑取证时文件已存在：留着已有的那份，不用报错。
                    print("[Silvics] seed template \(item.name) skipped: \(error.localizedDescription)")
                }
            }
        }
        if let raw = env["SILVICS_TEMPLATE_MEMORY"] {
            let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if !names.isEmpty { app.setJournalTemplateNames(names) }
        }
    }

    /// `SILVICS_VAULT` / `SILVICS_REMOTE` 预置同步配置，`SILVICS_SYNC=1` 启动即同步一次。
    /// 只用于取证：不预置的话，面板里的路径和远端要人手动填。
    @MainActor
    private static func applySyncFlags(_ app: AppState) {
        let env = ProcessInfo.processInfo.environment
        var settings = app.syncSettings
        var touched = false
        if let vault = env["SILVICS_VAULT"], !vault.isEmpty {
            settings.vaultPath = vault
            touched = true
        }
        if let remote = env["SILVICS_REMOTE"], !remote.isEmpty {
            settings.remoteURL = remote
            touched = true
        }
        if touched { app.saveSyncSettings(settings) }

        if env["SILVICS_SYNC"] == "1" {
            app.performSyncWork({ sync in
                let report = try sync.sync()
                DebugLog.write(
                    "sync: imported=\(report.importedNotes) removed=\(report.removedNotes) "
                    + "exported=\(report.exportedFiles) pushed=\(report.pushed) "
                    + "conflicts=\(report.conflicts.count)"
                )
                return [report.summary] + report.conflicts
            }, done: { lines in
                DebugLog.write("sync-done: " + lines.joined(separator: " | "))
            })
        }
    }

    /// 把 `NSVisualEffectView` 临时改成不透明背景色。
    ///
    /// 选中行的材质由 WindowServer 合成，离屏栅格化会画成黑块。
    /// 捕获前改成普通材质，事后原样恢复。
    @MainActor
    static func neutraliseEffectViews(in root: NSView) -> [NSVisualEffectView: (NSVisualEffectView.Material, NSVisualEffectView.BlendingMode, NSVisualEffectView.State)] {
        var saved: [NSVisualEffectView: (NSVisualEffectView.Material, NSVisualEffectView.BlendingMode, NSVisualEffectView.State)] = [:]
        func walk(_ view: NSView) {
            if let effect = view as? NSVisualEffectView {
                saved[effect] = (effect.material, effect.blendingMode, effect.state)
                effect.blendingMode = .withinWindow
                effect.material = .contentBackground
                effect.state = .inactive
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return saved
    }

    @MainActor
    static func restore(_ saved: [NSVisualEffectView: (NSVisualEffectView.Material, NSVisualEffectView.BlendingMode, NSVisualEffectView.State)]) {
        for (view, state) in saved {
            view.material = state.0
            view.blendingMode = state.1
            view.state = state.2
        }
    }

    /// 优先走 PDF 再栅格化。
    ///
    /// `cacheDisplay` 在侧栏的 `NSVisualEffectView`（选中行的材质）上会画成黑块，
    /// PDF 路径把材质当透明处理，观感与真机一致。
    private static func pngData(of view: NSView, bounds: NSRect) -> Data? {
        if ProcessInfo.processInfo.environment["SILVICS_CAPTURE_RASTER"] != "1" {
            let pdf = view.dataWithPDF(inside: bounds)
            if let rep = NSBitmapImageRep(data: pdf),
               let data = rep.representation(using: .png, properties: [:]) {
                return data
            }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// `SILVICS_SELFTEST=convert|tables`：走真实链路跑一次自检。
    ///
    /// - `convert`：把光标放进第一条提及，合成一次 `⌘⇧K`。
    /// - `tables`：量出每个表格每行 pipe 的 x，打印列偏差（验收需要具体数字）。
    @MainActor
    static func runSelfTest(_ app: AppState) {
        switch ProcessInfo.processInfo.environment["SILVICS_SELFTEST"] {
        case "convert": runConvertSelfTest(app)
        case "tables": runTableSelfTest()
        case "link-jump": runLinkJumpSelfTest(app)
        case "cursor-unfocused": runUnfocusedCursorSelfTest(app)
        case "ime": runIMESelfTest(app)
        case "watch": startIMEWatch(app)
        case "undo": runUndoSelfTest(app)
        case "undo-same": runUndoSameNoteSelfTest(app)
        case "undo-switch": runUndoSwitchSelfTest(app)
        case "undo-rename": runUndoRenameSelfTest(app)
        case "undo-spaced": runUndoSpacedSelfTest(app)
        default: return
        }
    }

    /// `SILVICS_SELFTEST=undo|undo-same|undo-switch|undo-rename`：查 ⌘Z 的三类症状（issue #35）。
    ///
    /// 每一步都读三处真值：可见正文、`app.current.body`、vault 文件里的正文。
    ///
    /// - `undo` / `undo-same`：键入 → ⌘Z（只退这一段）→ 再 ⌘Z（栈空，正文不动）
    ///   → 重做 → 落库。配 `SILVICS_UNDO_SHOTS=<dir>` 会存「键入后 / 撤销后 / 重做后」三张图。
    /// - `undo-switch`：A 篇键入 → 换到 B 篇 → 连按十次 ⌘Z，看 B 会不会被改成 A 的内容。
    /// - `undo-rename`：A 篇键入 → 改名（正文被整体重写）→ 按 ⌘Z，看会不会改坏。
    @MainActor
    private static func runUndoSelfTest(_ app: AppState, after delay: TimeInterval = 2.5) {
        runUndoDrill(app, mode: "same", after: delay)
    }

    @MainActor
    private static func runUndoSameNoteSelfTest(_ app: AppState, after delay: TimeInterval = 2.5) {
        runUndoDrill(app, mode: "same", after: delay)
    }

    @MainActor
    private static func runUndoSwitchSelfTest(_ app: AppState, after delay: TimeInterval = 2.5) {
        runUndoDrill(app, mode: "switch", after: delay)
    }

    @MainActor
    private static func runUndoRenameSelfTest(_ app: AppState, after delay: TimeInterval = 2.5) {
        runUndoDrill(app, mode: "rename", after: delay)
    }

    /// `undo-spaced`：停笔超过一个空闲间隔后继续打字，确认 ⌘Z 只退最后一段，不退整篇。
    @MainActor
    private static func runUndoSpacedSelfTest(_ app: AppState, after delay: TimeInterval = 2.5) {
        func log(_ line: String) {
            DebugLog.write("[undo:spaced] \(line)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let textView = findTextView(in: window.contentView!) as? EditorTextView else {
                log("找不到编辑区")
                return
            }
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            log("起长=\(textView.string.count) canUndo=\(textView.canUndoAction?().description ?? "nil")")
            func type(_ chars: [Character], at offset: Int, then next: @escaping () -> Void) {
                guard offset < chars.count else { next(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(offset + 1) * 0.4) {
                    MainActor.assumeIsolated {
                        textView.insertText(String(chars[offset]), replacementRange: textView.selectedRange())
                        log("键入 \(chars[offset]) 后 canUndo=\(textView.canUndoAction?().description ?? "nil")")
                        type(chars, at: offset + 1, then: next)
                    }
                }
            }
            type(Array("甲乙"), at: 0) {
                // 停笔超过 `UndoPolicy.idleInterval`（1.5 s），让撤销栈断开。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    MainActor.assumeIsolated {
                        log("停笔后=\(textView.string.count) 尾=\(String(textView.string.suffix(4)).debugDescription)")
                        type(Array("丙丁戊"), at: 0) {
                            log("再键入后=\(textView.string.count) 尾=\(String(textView.string.suffix(8)).debugDescription)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                MainActor.assumeIsolated {
                                    _ = NSApp.mainMenu?.performKeyEquivalent(with: NSEvent.keyEvent(
                                        with: .keyDown, location: .zero, modifierFlags: [.command],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: "z", charactersIgnoringModifiers: "z",
                                        isARepeat: false, keyCode: 6
                                    )!)
                                    log("⌘Z后=\(textView.string.count) 尾=\(String(textView.string.suffix(8)).debugDescription)")
                                    var round = 0
                                    while textView.canUndoAction?() == true, round < 8 {
                                        round += 1
                                        _ = textView.onUndo?()
                                        log("  再撤#\(round)=\(textView.string.count) 尾=\(String(textView.string.suffix(6)).debugDescription)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private static func runUndoDrill(_ app: AppState, mode: String, after delay: TimeInterval) {
        func log(_ line: String) {
            DebugLog.write("[undo:\(mode)] \(line)")
        }
        func vaultBody(_ id: String) -> String {
            let url = app.repo.vaultURL
                .appendingPathComponent(VaultFormat.notesDir, isDirectory: true)
                .appendingPathComponent(VaultFormat.fileName(for: id))
            return (try? String(contentsOf: url, encoding: .utf8)) ?? "<读不到>"
        }
        @MainActor func dump(_ tag: String, window: NSWindow?, textView: NSTextView?) {
            let visible = textView?.string ?? "<无>"
            let title = app.current?.title ?? "<无>"
            let files = app.summaries.prefix(3).map { s in
                "\(s.title):\(vaultBody(s.id).count)"
            }.joined(separator: " ")
            let editor = textView as? EditorTextView
            let canUndo = editor?.canUndoAction?().description ?? "nil"
            let canRedo = editor?.canRedoAction?().description ?? "nil"
            let tail = String(visible.suffix(8)).debugDescription
            let bodyCount = app.current?.body.count ?? -1
            let status = app.statusMessage ?? "-"
            log("\(tag) 当前=\(title) 可见=\(visible.count) 尾=\(tail) current=\(bodyCount)"
                + " canUndo=\(canUndo) canRedo=\(canRedo) 状态=\(status) 文件=\(files)")
        }
        /// 截图前清掉状态提示条：它浮在正文上，会挡住要看的字。
        @MainActor func shot(_ tag: String, window: NSWindow?) {
            guard let shots = ProcessInfo.processInfo.environment["SILVICS_UNDO_SHOTS"] else { return }
            app.statusMessage = nil
            // 窗口不激活时侧栏会变暗，截图之间会多出整块差异。截前先激活。
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            captureNow(prefix: shots, tag: tag)
        }
        @MainActor func menuProbe(_ title: String) -> String {
            let item = NSApp.mainMenu?.items
                .compactMap { $0.submenu?.items }
                .flatMap { $0 }
                .first { $0.title == title }
            guard let item else { return "\(title)=缺" }
            let action = item.action.map { NSStringFromSelector($0) } ?? "nil"
            let target = item.target.map { String(describing: type(of: $0)) } ?? "nil"
            let routed = item.action.flatMap { NSApp.target(forAction: $0, to: nil, from: item) }
                .map { String(describing: type(of: $0)) } ?? "nil"
            return "\(title): action=\(action) target=\(target) 路由=\(routed) enabled=\(item.isEnabled ? "on" : "off")"
        }
        @MainActor func pressUndo(_ window: NSWindow) -> Bool {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "z", charactersIgnoringModifiers: "z",
                isARepeat: false, keyCode: 6
            ) else { return false }
            return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let textView = findTextView(in: window.contentView!) as? EditorTextView,
                  let startNote = app.current else {
                log("找不到编辑区")
                return
            }
            log("A=\(startNote.title) (\(startNote.id)) 原长=\(textView.string.count)")
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            for ch in "【撤销测试】" {
                textView.insertText(String(ch), replacementRange: textView.selectedRange())
            }
            // 截图要能看见刚键入的那一段：滚到正文末尾（撤销前后都以末尾为锚，便于逐像素对比）。
            scrollToEnd(textView)
            dump("键入后", window: window, textView: textView)
            log("菜单 \(menuProbe("Undo")) | \(menuProbe("Redo"))")
            shot("01-键入后", window: window)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated {
                    app.flushPendingSave()
                    dump("落库后", window: window, textView: textView)
                    switch mode {
                    case "rename":
                        let old = startNote.title
                        app.rename(newTitle: old + "改")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            MainActor.assumeIsolated {
                                let fresh = findTextView(in: window.contentView!) as? EditorTextView
                                dump("改名后", window: window, textView: fresh)
                                _ = pressUndo(window)
                                dump("⌘Z后", window: window,
                                     textView: findTextView(in: window.contentView!) as? EditorTextView)
                            }
                        }
                    case "switch":
                        guard let other = app.summaries.first(where: { $0.id != startNote.id }) else {
                            log("只有一篇笔记，无法换")
                            return
                        }
                        app.select(other.id)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            MainActor.assumeIsolated {
                                var currentText: EditorTextView? = findTextView(in: window.contentView!) as? EditorTextView
                                dump("换到B", window: window, textView: currentText)
                                shot("04-换到B", window: window)
                                for i in 1...10 {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                                        MainActor.assumeIsolated {
                                            _ = pressUndo(window)
                                            currentText = findTextView(in: window.contentView!) as? EditorTextView
                                            dump("⌘Z#\(i)", window: window, textView: currentText)
                                            if i == 1 { shot("05-B上撤销", window: window) }
                                        }
                                    }
                                }
                            }
                        }
                    default:
                        func editorNow() -> EditorTextView? {
                            findTextView(in: window.contentView!) as? EditorTextView
                        }
                        func step(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                MainActor.assumeIsolated(body)
                            }
                        }
                        step(0.3) {
                            _ = pressUndo(window)
                            dump("⌘Z#1", window: window, textView: editorNow())
                        }
                        step(0.8) {
                            if let editor = editorNow() { scrollToEnd(editor) }
                            shot("02-撤销后", window: window)
                        }
                        step(1.4) {
                            _ = pressUndo(window)
                            dump("⌘Z#2（栈已空）", window: window, textView: editorNow())
                        }
                        step(1.9) {
                            let redone = NSApp.sendAction(
                                #selector(EditorTextView.redo(_:)), to: editorNow(), from: nil
                            )
                            log("重做 处理=\(redone)")
                            dump("⌘⇧Z", window: window, textView: editorNow())
                        }
                        step(2.4) {
                            if let editor = editorNow() { scrollToEnd(editor) }
                            shot("03-重做后", window: window)
                            log("菜单 \(menuProbe("Undo")) | \(menuProbe("Redo"))")
                        }
                        step(2.9) {
                            app.flushPendingSave()
                            dump("落库后", window: window, textView: editorNow())
                        }
                        step(3.4) {
                            // 撤销后的正文必须真的落库，否则下次启动又回来。
                            _ = pressUndo(window)
                            app.flushPendingSave()
                            dump("再撤并落库", window: window, textView: editorNow())
                        }
                    }
                }
            }
        }
    }

    /// `SILVICS_SELFTEST=link-jump`：查「换笔记之后指针还认不认 ⌘」。
    @MainActor
    private static func runLinkJumpSelfTest(_ app: AppState, after delay: TimeInterval = 2.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let content = window.contentView,
                  let old = findTextView(in: content) as? EditorTextView else {
                DebugLog.write("[link-jump] 找不到编辑区")
                return
            }
            let links = WikiScanner.scan(old.string)
            DebugLog.write("[link-jump] 跳转前：第一响应者=\(window.firstResponder === old) 引用数=\(links.count)")
            measureCursor(tag: "跳转前", editor: old, window: window)
            guard let link = links.first else {
                DebugLog.write("[link-jump] 这篇没有引用，换一篇测")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                app.openTitle(link.target)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let fresh = findTextView(in: content) as? EditorTextView else {
                        DebugLog.write("[link-jump] 跳转后找不到编辑区")
                        return
                    }
                    DebugLog.write("[link-jump] 跳转后：同一视图=\(fresh === old) 第一响应者=\(window.firstResponder === fresh)")
                    measureCursor(tag: "跳转后", editor: fresh, window: window)
                }
            }
        }
    }

    /// `SILVICS_SELFTEST=cursor-unfocused`：编辑视图没有焦点时，按 ⌘ 指针还变不变手型。
    ///
    /// 等价于「⌘ 点击链接跳转到新笔记，新编辑视图还没拿到焦点」。
    /// 事件走 `NSApp.postEvent`，会被 App 的事件循环取出，窗口级监听能收到；
    /// 旧实现只靠第一响应者收 `flagsChanged`，这里应当完全没反应。
    @MainActor
    private static func runUnfocusedCursorSelfTest(_ app: AppState, after delay: TimeInterval = 2.5) {
        // 先切到一篇确定含 [[ ]] 的笔记，避免「当前这篇没有引用」导致空跑。
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay - 1.5)) {
            app.openTitle("稀疏重复优于集中突击")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let content = window.contentView,
                  let editor = findTextView(in: content) as? EditorTextView else {
                DebugLog.write("[cursor-unfocused] 找不到编辑区")
                return
            }
            window.makeFirstResponder(nil)
            DebugLog.write("[cursor-unfocused] 编辑视图第一响应者=\(window.firstResponder === editor)"
                + " 手型矩形=\(editor.wikiLinkCursorRects().count) 装监听=\(editor.isObservingModifierChanges)")

            guard let rect = editor.wikiLinkCursorRects().first else {
                DebugLog.write("[cursor-unfocused] 没有手型矩形，跳过")
                return
            }
            let inWindow = editor.convert(rect, to: nil)
            let onScreen = window.convertToScreen(inWindow)
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: onScreen.midX, y: screenHeight - onScreen.midY))

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                // 系统修饰键状态在锁屏下无法稳定保持，这里用产品代码里同一个注入点把 ⌘ 置为按住；
                // 投递路径仍然是「App 事件队列 → 窗口级监听」，不是直接调函数。
                editor.debugModifierOverride = [.command]
                let flags = NSEvent.modifierFlags
                if let event = NSEvent.keyEvent(
                    with: .flagsChanged, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: 55
                ) {
                    NSApp.postEvent(event, atStart: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    DebugLog.write("[cursor-unfocused] 注入的 ⌘=\(editor.debugModifierOverride?.contains(.command) == true)"
                        + " \(editor.debugCursorReport())")
                    editor.debugModifierOverride = nil
                }
            }
        }
    }

    @MainActor
    private static func measureCursor(tag: String, editor: EditorTextView, window: NSWindow) {
        let rects = editor.wikiLinkCursorRects()
        guard let rect = rects.first else {
            DebugLog.write("[link-jump] \(tag)：没有手型矩形，跳过")
            return
        }
        let inWindow = editor.convert(rect, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.midX, y: screenHeight - onScreen.midY))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let flags = NSEvent.modifierFlags
            if let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 55
            ) {
                window.sendEvent(event)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                DebugLog.write("[link-jump] \(tag)：系统修饰键=\(flags.contains(.command)) \(editor.debugCursorReport())")
            }
        }
    }

    /// `SILVICS_SELFTEST=tables`：把每行 pipe 的 x 量出来，打印列偏差。
    ///
    /// 用 `firstRect(forCharacterRange:)` 量真实排版结果，不看属性表推算。
    @MainActor
    private static func runTableSelfTest(after delay: TimeInterval = 2.8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let textView = findTextView(in: window.contentView!) else {
                print("[tables] 找不到编辑区")
                return
            }
            let text = textView.string
            let blocks = TableLayout.blocks(in: text)
            print("[tables] 识别到表格块 \(blocks.count) 个")
            if let manager = textView.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            window.layoutIfNeeded()
            textView.layoutSubtreeIfNeeded()
            let origin = textView.textContainerOrigin

            func x(_ location: Int) -> CGFloat {
                var actual = NSRange()
                let rect = textView.firstRect(
                    forCharacterRange: NSRange(location: location, length: 1),
                    actualRange: &actual
                )
                let inView = textView.convert(window.convertFromScreen(rect), from: nil)
                return inView.minX - origin.x
            }

            for (index, block) in blocks.enumerated() {
                print("[tables] 块 \(index + 1)：\(block.columnCount) 列 / \(block.rows.count) 行")
                let rows = block.rows.map { row in row.pipes.map { x($0.location) } }
                for (r, row) in rows.enumerated() {
                    print("[tables]   第 \(r + 1) 行："
                        + row.map { String(format: "%.2f", $0) }.joined(separator: " / "))
                }
                var worst: CGFloat = 0
                for column in 1...block.columnCount {
                    let xs = rows.compactMap { $0.count > column ? $0[column] : nil }
                    guard let lo = xs.min(), let hi = xs.max() else { continue }
                    worst = max(worst, hi - lo)
                    print(String(
                        format: "[tables]   第 %d 个 | 偏差 %.2f pt（x∈[%.2f, %.2f]）",
                        column + 1, hi - lo, lo, hi
                    ))
                }
                print(String(format: "[tables]   最大列偏差 %.2f pt", worst))
            }
        }
    }

    /// `SILVICS_SELFTEST=convert`：把光标放进第一条提及，合成一次 `⌘⇧K`。
    ///
    /// 走的是真实的 `keyDown` → `shouldChangeText` → 正文改写 → 防抖保存链路，
    /// 只是绕开系统键盘事件（自动化按键要「辅助功能」授权）。
    @MainActor
    private static func runConvertSelfTest(_ app: AppState) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let textView = findTextView(in: window.contentView!) else {
                print("[selftest] 找不到编辑区")
                return
            }
            guard let mention = app.mentions.first else {
                print("[selftest] 当前笔记没有提及")
                return
            }
            let caret = mention.location + 1
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "K",
                charactersIgnoringModifiers: "k",
                isARepeat: false,
                keyCode: 40
            ) else { return }
            textView.keyDown(with: event)
            print("[selftest] 已在 caret=\(caret) 发送 ⌘⇧K，目标《\(mention.targetTitle)》")
        }
    }

    /// 仅用于取证：`SILVICS_CONFLICT_DEMO=1` 塞一组冲突并打开冲突面板，
    /// 值为 `merge` 时再自动跑一次 LLM 合并，便于截图「合并结果 + diff」。
    @MainActor
    static func seedConflictDemo(_ app: AppState) {
        guard let mode = ProcessInfo.processInfo.environment["SILVICS_CONFLICT_DEMO"] else { return }
        let base = """
        第一段：写作工具的核心指标是每次开口的摩擦。
        第二段：间隔重复优于集中突击。
        第三段：结论先写下来，再补理由。
        """
        let ours = base.replacingOccurrences(of: "第二段：间隔重复优于集中突击。",
                                             with: "第二段：间隔重复优于集中突击，但每天只能练 20 分钟。")
        let theirs = base.replacingOccurrences(of: "第二段：间隔重复优于集中突击。",
                                               with: "第二段：间隔重复优于集中突击，前提是总时长相同。")
        app.refreshProviders()
        if app.providerSettings.providers.isEmpty, let preset = ProviderPresets.named("magpie（本地）") {
            let config = preset.config()
            _ = app.saveProvider(config, secret: nil)
            app.bindProvider(.chat, to: config.id)
        }
        app.debugSetConflicts([
            VaultConflict(noteId: "demo-1", title: "间隔重复优于集中突击", base: base, ours: ours, theirs: theirs)
        ])
        app.isShowingConflicts = true

        guard mode == "merge" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let conflict = VaultConflict(noteId: "demo-1", title: "间隔重复优于集中突击",
                                         base: base, ours: ours, theirs: theirs)
            Task {
                if case .success = await app.resolveConflictWithLLM(conflict) {
                    print("[Silvics] conflict demo merged")
                }
            }
        }
    }

    /// 仅用于取证：模拟两台设备改同一个笔记文件造成冲突，再用 magpie 的对话模型合并。
    ///
    /// `SILVICS_CONFLICT_DRILL=1`。流程：建裸仓 → 两个 clone → 同样两行改成不同内容 →
    /// 一个 push、另一个 fetch → 用 `LineMerge` 复现冲突 → 交给 `ConflictResolver`。
    @MainActor
    static func runConflictDrill(_ app: AppState) {
        guard ProcessInfo.processInfo.environment["SILVICS_CONFLICT_DRILL"] == "1" else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("silvics-drill")
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var logText = ""
            func log(_ line: String) {
                logText += line + "\n"
                print(line)
            }
            func flushLog() {
                try? logText.write(to: root.appendingPathComponent("drill.log"), atomically: true, encoding: .utf8)
            }

            func git(_ cwd: URL, _ args: [String]) -> String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = args
                p.currentDirectoryURL = cwd
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                try? p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }

            let bare = root.appendingPathComponent("remote.git")
            _ = git(root, ["init", "--bare", "-q", bare.path])

            let base = """
            第一段：这是共同基线。
            第二段：间隔重复优于集中突击。
            第三段：结尾。
            """

            let deviceA = root.appendingPathComponent("deviceA")
            _ = git(root, ["clone", "-q", bare.path, deviceA.path])
            _ = git(deviceA, ["config", "user.email", "a@local"])
            _ = git(deviceA, ["config", "user.name", "A"])
            _ = git(deviceA, ["checkout", "-q", "-b", "main"])
            let noteFile = deviceA.appendingPathComponent("notes/n1.md")
            try? FileManager.default.createDirectory(at: noteFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? base.write(to: noteFile, atomically: true, encoding: .utf8)
            _ = git(deviceA, ["add", "-A"])
            _ = git(deviceA, ["commit", "-q", "-m", "base"])
            _ = git(deviceA, ["push", "-q", "origin", "main"])

            let deviceB = root.appendingPathComponent("deviceB")
            _ = git(root, ["clone", "-q", "-b", "main", bare.path, deviceB.path])
            _ = git(deviceB, ["config", "user.email", "b@local"])
            _ = git(deviceB, ["config", "user.name", "B"])

            // A 改第二段
            let oursA = base.replacingOccurrences(of: "第二段：间隔重复优于集中突击。",
                                                  with: "第二段：间隔重复优于集中突击，但每天只能练 20 分钟。")
            try? oursA.write(to: noteFile, atomically: true, encoding: .utf8)
            _ = git(deviceA, ["commit", "-q", "-am", "A 改"])
            _ = git(deviceA, ["push", "-q"])

            // B 改同一段，内容不同
            let theirsB = base.replacingOccurrences(of: "第二段：间隔重复优于集中突击。",
                                                    with: "第二段：间隔重复优于集中突击，前提是总时长相同。")
            let noteFileB = deviceB.appendingPathComponent("notes/n1.md")
            try? theirsB.write(to: noteFileB, atomically: true, encoding: .utf8)
            _ = git(deviceB, ["commit", "-q", "-am", "B 改"])
            _ = git(deviceB, ["fetch", "-q"])

            let conflictOurs = theirsB
            let conflictTheirs = oursA
            let merge = LineMerge.merge(base: base, ours: conflictOurs, theirs: conflictTheirs)
            log("[drill] 两台设备改了同一段")
            log("[drill] LineMerge 干净合并: \(merge?.isClean ?? false) 冲突数: \(merge?.conflictCount ?? -1)")

            let conflict = VaultConflict(noteId: "n1", title: "设备 A / B 同改一段",
                                         base: base, ours: conflictOurs, theirs: conflictTheirs)
            let provider = ProviderPresets.named("magpie（本地）")!.config()

            let semaphore = DispatchSemaphore(value: 0)
            Task {
                let started = CFAbsoluteTimeGetCurrent()
                let result = await ConflictResolver.resolve(conflict, provider: provider, key: "")
                let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                switch result {
                case .success(let text):
                    log("[drill] LLM 合并成功 (\(ms) ms)：")
                    log(text)
                case .failure(let error):
                    log("[drill] LLM 合并失败 (\(ms) ms)：\(error.message)")
                }
                semaphore.signal()
            }
            semaphore.wait()
            flushLog()
        }
    }

    /// 仅用于取证：加一个假的 OpenAI 配置，验证 Keychain 写入与「已配置密钥」状态。
    @MainActor
    static func seedDemoProvider(_ app: AppState) {
        app.refreshProviders()
        guard app.providerSettings.providers.isEmpty,
              let preset = ProviderPresets.named("OpenAI") else { return }
        let config = preset.config()
        let errors = app.saveProvider(config, secret: "sk-demo-invalid-0000")
        if errors.isEmpty {
            app.bindProvider(.chat, to: config.id)
            print("[Silvics] seeded demo provider")
        } else {
            print("[Silvics] seed provider failed: \(errors)")
        }
    }

    private static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    /// 所有 NSTextView（含编辑区与搜索框的 field editor）。
    private static func textViews(in view: NSView, into out: inout [NSTextView]) {
        if let textView = view as? NSTextView { out.append(textView) }
        for sub in view.subviews { textViews(in: sub, into: &out) }
    }

    /// 仅用于取证：`SILVICS_CARET=<文本>` 把光标放到含该文本的段落。
    ///
    /// 「光标行露源码」只能靠截图验收，而截图需要能指定光标位置。
    /// 走真实 `setSelectedRange` → `textViewDidChangeSelection` → 重刷标记可见性这条链路。
    @MainActor
    static func applyCaretProbe(after delay: TimeInterval = 1.4) {
        guard let keyword = ProcessInfo.processInfo.environment["SILVICS_CARET"], !keyword.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var candidates: [NSTextView] = []
            for window in NSApp.windows where window.isVisible {
                if let content = window.contentView { textViews(in: content, into: &candidates) }
            }
            for textView in candidates {
                let range = (textView.string as NSString).range(of: keyword)
                guard range.location != NSNotFound else { continue }
                textView.window?.makeFirstResponder(textView)
                // `SILVICS_CARET_SELECT=1` 时选中关键字：截图里能看出是哪一行「露源码」。
                let length = ProcessInfo.processInfo.environment["SILVICS_CARET_SELECT"] == "1"
                    ? range.length : 0
                textView.setSelectedRange(NSRange(location: range.location, length: length))
                print("[caret] \"\(keyword)\" -> location=\(range.location) length=\(length)")
                return
            }
            print("[caret] 可见文本视图里找不到「\(keyword)」")
        }
    }

    /// 仅取证：`SILVICS_CURSOR_PROBE=1` 时每 0.5 秒打印一次指针状态。
    ///
    /// 指针形状截不进图（`screencapture -C` 在本机不画光标），
    /// 只能把「⌘ 按下 / 松开时指针是不是手型」写成日志当证据。
    @MainActor
    static func startCursorProbe(interval: TimeInterval = 0.5, ticks: Int = 600) {
        guard ProcessInfo.processInfo.environment["SILVICS_CURSOR_PROBE"] != nil else { return }
        var remaining = ticks
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            remaining -= 1
            if remaining <= 0 { timer.invalidate() }
            Task { @MainActor in
                var reports: [String] = []
                for window in NSApp.windows where window.isVisible {
                    guard let content = window.contentView else { continue }
                    var views: [NSTextView] = []
                    textViews(in: content, into: &views)
                    for case let editor as EditorTextView in views {
                        reports.append(editor.debugCursorReport())
                    }
                }
                // 写文件不用 print：stdout 重定向到文件是块缓冲，探针会看不到。
                DebugLog.write("[cursor-probe] " + reports.joined(separator: " | "))
            }
        }
    }

    /// 把编辑区滚到正文末尾。撤销前后都用同一个锚点，截图才能逐像素对比。
    @MainActor
    static func scrollToEnd(_ textView: NSTextView) {
        let end = (textView.string as NSString).length
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
    }

    /// 立刻把主窗口写成 PNG。撤销演练用它取「键入后 / 撤销后 / 重做后」三张图。
    @MainActor
    static func captureNow(prefix: String, tag: String) {
        let path = "\(prefix)/\(tag).png"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            captureAll(to: path)
        }
    }

    /// 延迟后把所有可见窗口写成 PNG。
    @MainActor
    static func schedule(after delay: TimeInterval = 2.2) {
        guard let path else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            captureAll(to: path)
        }
    }

    @MainActor
    private static func captureAll(to path: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.contentView?.bounds.width ?? 0 > 80 }
        guard !windows.isEmpty else {
            print("[Silvics] capture: 没有可见窗口")
            return
        }
        for (index, window) in windows.enumerated() {
            guard let view = window.contentView else { continue }
            let bounds = view.bounds
            let restored = Self.neutraliseEffectViews(in: view)
            let data = Self.pngData(of: view, bounds: bounds)
            Self.restore(restored)
            guard let data else { continue }
            let target = windows.count == 1 ? path : path.replacingOccurrences(of: ".png", with: "-\(index).png")
            let url = URL(fileURLWithPath: target)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            do {
                try data.write(to: url)
                print("[Silvics] captured \(target) (\(Int(bounds.width))x\(Int(bounds.height)))")
            } catch {
                print("[Silvics] capture failed: \(error)")
            }
        }
    }

    /// `SILVICS_SELFTEST=ime`：模拟系统中文输入法连敲几个词，逐步打印各层正文。
    ///
    /// 输入法在 AppKit 层只做两件事：`setMarkedText`（组合态）与 `insertText`（上屏）。
    /// 按这个接口驱动真实的 `EditorTextView`，就会走 `textDidChange` → 重排样式 →
    /// 防抖保存 → SwiftUI 回灌这一整条链路，和真人敲拼音同路。
    ///
    /// 步间隔默认 0.8 s，比 500 ms 的防抖保存宽，好让保存与回灌落在两步之间。
    /// `SILVICS_IME_GAP` 可改间隔（秒）。
    @MainActor
    private static func runIMESelfTest(_ app: AppState, after delay: TimeInterval? = nil) {
        let env = ProcessInfo.processInfo.environment
        let delay = delay ?? Double(env["SILVICS_IME_DELAY"] ?? "") ?? 2.5
        let gap = Double(env["SILVICS_IME_GAP"] ?? "") ?? 0.8
        let words = ["你好", "世界", "输入法", "吞字", "复现"]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            app.openTitle("中文输入是笔记应用的关键路径")
            var waited = 0
            while (app.current == nil || app.current?.type == NoteTypes.clipID) && waited < 40 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let textView = findEditorTextView(in: window.contentView!) else {
                print("[ime] 找不到编辑区 标题=\(app.current?.title ?? "nil") 笔记数=\(app.summaries.count)")
                return
            }
            window.makeFirstResponder(textView)
            let base = textView.string
            textView.setSelectedRange(NSRange(location: (base as NSString).length, length: 0))
            print("[ime] 起始 长度=\((base as NSString).length) 尾部=\(tail(base))"
                + " 标题=\(app.current?.title ?? "nil") 建视图次数=\(NoteEditorView.makeCount)")

            var expectation = base
            var checks: [(String, Bool)] = []

            for (index, word) in words.enumerated() {
                // 每步取当前树上的编辑区，别拿到已被替换掉的旧视图。
                let live = findEditorTextView(in: window.contentView!) ?? textView
                if live.window?.firstResponder !== live { window.makeFirstResponder(live) }
                let pinyin = "nihao"
                live.setMarkedText(
                    pinyin,
                    selectedRange: NSRange(location: (pinyin as NSString).length, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                let markedTail = tail(live.string)
                let marked = live.hasMarkedText()
                live.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))

                expectation += word
                let viewNow = live.string
                let appBody = app.current?.body ?? ""
                let ok = viewNow == expectation && appBody == expectation
                checks.append(("第 \(index + 1) 步 上屏「\(word)」", ok))
                print("[ime] 第 \(index + 1) 步 组合态 marked=\(marked) 尾部=\(markedTail)")
                print("[ime] 第 \(index + 1) 步 上屏「\(word)」 视图长度=\((viewNow as NSString).length)"
                    + " 视图一致=\(viewNow == expectation) 应用长度=\((appBody as NSString).length)"
                    + " 应用一致=\(appBody == expectation) 光标=\(live.selectedRange().location)"
                    + " 尾部=\(tail(viewNow))")
                try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            }

            // 第 6 步：保存触发的重渲染与新输入落在同一轮 runloop。
            //
            // `flushPendingSave` 会发布一批状态（列表、引用、提及），SwiftUI 因此排一轮渲染；
            // 那轮渲染手里的正文是「敲字之前」的快照。用户恰在这时又敲了一个词，
            // 旧实现等渲染落地就把新词按快照写回，于是吞字。
            do {
                let live = findEditorTextView(in: window.contentView!) ?? textView
                app.flushPendingSave()
                live.insertText("吞字", replacementRange: NSRange(location: NSNotFound, length: 0))
                expectation += "吞字"
                try? await Task.sleep(nanoseconds: UInt64(max(gap, 0.8) * 1_000_000_000))
                let after = (findEditorTextView(in: window.contentView!) ?? live).string
                checks.append(("第 6 步 保存后同一轮敲字", after == expectation))
                print("[ime] 第 6 步 保存后同一轮敲字 长度=\((after as NSString).length)"
                    + " 保住=\(after == expectation) 尾部=\(tail(after))")
            }

            // 第 7 步：组合态里连按两键，中间夹着 SwiftUI 的一轮渲染。
            //
            // 输入法每次按键都 `setMarkedText` → `textDidChange` → 发布；
            // 上一轮渲染手里的正文比视图少一个字母，若按它重设整篇，
            // 组合就被截断（`hasMarkedText` 变 false，候选窗消失），随后上屏少字。
            do {
                let live = findEditorTextView(in: window.contentView!) ?? textView
                live.setMarkedText(
                    "nihao",
                    selectedRange: NSRange(location: 5, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                live.setMarkedText(
                    "nihaoa",
                    selectedRange: NSRange(location: 6, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                print("[ime] 第 7 步 连按两键后立刻 marked=\(live.hasMarkedText()) 尾部=\(tail(live.string))")
                try? await Task.sleep(nanoseconds: 300_000_000)
                let settled = findEditorTextView(in: window.contentView!) ?? live
                let marked = settled.hasMarkedText()
                checks.append(("第 7 步 组合串不被截断", marked))
                print("[ime] 第 7 步 渲染落地后 marked=\(marked)"
                    + " 尾部=\(tail(settled.string)) 组合串=\(marked ? "在" : "被截断")")
                settled.unmarkText()
                expectation += "nihaoa"
                try? await Task.sleep(nanoseconds: UInt64(max(gap, 0.5) * 1_000_000_000))
            }

            // 第 8 步：组合态里正文被外部改写（同步导入、改名、批量转换都会这样）。
            //
            // 旧实现在这一下把整篇重设成库里的正文：拼音消失、`hasMarkedText` 变 false，
            // 输入法候选窗被顶掉，后续上屏就少字。新实现把外部正文排在组合结束之后。
            do {
                let live = findEditorTextView(in: window.contentView!) ?? textView
                live.setMarkedText(
                    "nihao",
                    selectedRange: NSRange(location: 5, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                let composing = live.hasMarkedText()
                if let id = app.current?.id { app.loadNote(id: id) }
                try? await Task.sleep(nanoseconds: 400_000_000)
                let settled = findEditorTextView(in: window.contentView!) ?? live
                let marked = settled.hasMarkedText()
                checks.append(("第 8 步 组合期外部改写不打断组合", composing && marked))
                print("[ime] 第 8 步 组合期外部改写 改写前组合=\(composing)"
                    + " 改写后组合=\(marked) 尾部=\(tail(settled.string))")
                settled.unmarkText()
                expectation += "nihao"
                try? await Task.sleep(nanoseconds: UInt64(max(gap, 0.5) * 1_000_000_000))
            }

            // 等最后一轮防抖保存与回灌走完，再判最终结果。
            try? await Task.sleep(nanoseconds: UInt64(max(gap, 0.8) * 1_000_000_000))
            let live = findEditorTextView(in: window.contentView!) ?? textView
            let viewNow = live.string
            let appBody = app.current?.body ?? ""
            let failed = checks.filter { !$0.1 }.map(\.0)
            print("[ime] 判据 " + checks.map { "\($0.0)=\($0.1 ? "通过" : "失败")" }.joined(separator: " / "))
            print("[ime] 结论 \(failed.isEmpty ? "全部通过" : "有失败")"
                + " 期望长度=\((expectation as NSString).length)"
                + " 视图长度=\((viewNow as NSString).length)"
                + " 应用长度=\((appBody as NSString).length)"
                + " 文本一致=\(viewNow == expectation && appBody == expectation)"
                + " 建视图次数=\(NoteEditorView.makeCount)")
            if let diff = firstDiff(expectation, viewNow) {
                print("[ime] 视图首个差异 期望=\(tailDiff(expectation, diff)) 实际=\(tailDiff(viewNow, diff))")
            }
            if let diff = firstDiff(expectation, appBody) {
                print("[ime] 应用首个差异 期望=\(tailDiff(expectation, diff)) 实际=\(tailDiff(appBody, diff))")
            }
            print("[ime] 末段 视图=\(tail(viewNow)) 应用=\(tail(appBody))")
            // 取证：滚到末尾再截图，图上是「最后敲的字在不在」的直接证据。
            let caretEnd = NSRange(location: (live.string as NSString).length, length: 0)
            live.setSelectedRange(caretEnd)
            live.scrollRangeToVisible(caretEnd)
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let path {
                let stem = path.hasSuffix(".png") ? String(path.dropLast(4)) : path
                captureAll(to: stem + "-ime.png")
            }
            // 取证脚本跑完自己退出，外部不用去 kill（kill 掉会丢标准输出）。
            if ProcessInfo.processInfo.environment["SILVICS_QUIT_AFTER_SELFTEST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        }
    }

    /// `SILVICS_SELFTEST=watch`：只盯不清，每 0.4 s 打印一次正文尾部。
    ///
    /// 配合外部工具往进程里投递真实键盘事件，用来验证系统输入法下的行为。
    @MainActor
    static func startIMEWatch(_ app: AppState) {
        Task { @MainActor in
            var last = ""
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let body = app.current?.body ?? ""
                if body != last {
                    print("[watch] 长度=\((body as NSString).length) 尾部=\(tail(body, 18))"
                        + " 组合态=\(findEditorTextView(in: NSApp.windows.first?.contentView ?? NSView())?.hasMarkedText() ?? false)"
                        + " 输入源=\(currentInputSource())")
                    last = body
                }
            }
        }
    }

    /// `SILVICS_IME_SOURCE=1`：从进程内部切到简体拼音输入源。
    ///
    /// 从外部进程调 `TISSelectInputSource` 在本机不生效（App 仍报 ABC），
    /// 只有 App 自己切才会真的换过去。
    @MainActor
    static func selectPinyinInputSourceIfRequested() {
        guard ProcessInfo.processInfo.environment["SILVICS_IME_SOURCE"] == "1" else { return }
        let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        for source in list {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            if id.contains("SCIM.ITABC") {
                let status = TISSelectInputSource(source)
                print("[ime-source] 选中 \(id) status=\(status) 现在=\(currentInputSource())")
                return
            }
        }
        print("[ime-source] 没找到简体拼音输入源")
    }

    /// 当前输入源名字，用来确认真的在拼音输入法下打字。
    @MainActor
    static func currentInputSource() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            return "unknown"
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// 只找编辑区的 `EditorTextView`，不要拿列表栏搜索框的 field editor 充数。
    private static func findEditorTextView(in view: NSView) -> EditorTextView? {
        if let textView = view as? EditorTextView { return textView }
        for sub in view.subviews {
            if let found = findEditorTextView(in: sub) { return found }
        }
        return nil
    }

    private static func tail(_ text: String, _ count: Int = 12) -> String {
        let ns = text as NSString
        let start = max(0, ns.length - count)
        return ns.substring(with: NSRange(location: start, length: ns.length - start))
            .replacingOccurrences(of: "\n", with: "⏎")
    }

    private static func firstDiff(_ a: String, _ b: String) -> Int? {
        let lhs = Array(a.utf16)
        let rhs = Array(b.utf16)
        for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] { return index }
        return lhs.count == rhs.count ? nil : min(lhs.count, rhs.count)
    }

    private static func tailDiff(_ text: String, _ offset: Int) -> String {
        let ns = text as NSString
        let start = max(0, min(offset, ns.length) - 4)
        return ns.substring(with: NSRange(location: start, length: min(12, ns.length - start)))
    }

}
#endif
