#if DEBUG
import AppKit
import SwiftUI

/// 仅 DEBUG：把窗口自己画成 PNG，用于验收取证。
///
/// 为什么不用 `screencapture`：它要「屏幕录制」授权，而授权只能人工在系统设置里给。
/// `cacheDisplay` 是 App 画自己的视图，不需要任何授权，也不受窗口遮挡影响。
///
/// 两个环境变量：
/// - `SILVICS_CAPTURE=/tmp/reports/x.png`：图片路径前缀。有多个可见窗口时追加 `-1`、`-2`。
/// - `SILVICS_SHOW=quickopen|mentions|alias|rename`：启动后直接打开对应面板，便于截取。
enum DebugCapture {

    static var path: String? {
        ProcessInfo.processInfo.environment["SILVICS_CAPTURE"]
    }

    static var showPanel: String? {
        ProcessInfo.processInfo.environment["SILVICS_SHOW"]
    }

    /// 启动时按环境变量打开面板。
    @MainActor
    static func applyShowFlag(_ app: AppState) {
        // SILVICS_APPEARANCE="body=18,code=14,spacing=7,family=serif"：取证时预置外观。
        if let raw = ProcessInfo.processInfo.environment["SILVICS_APPEARANCE"] {
            var settings = app.appearance
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=").map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "body": settings.bodySize = Double(parts[1]) ?? settings.bodySize
                case "code": settings.codeSize = Double(parts[1]) ?? settings.codeSize
                case "spacing": settings.lineSpacing = Double(parts[1]) ?? settings.lineSpacing
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
            app.select(match.id)
        }
        switch showPanel {
        case "quickopen": app.isShowingQuickOpen = true
        case "mentions", "mentions-preview":
            app.refreshMentionGroups()
            app.isShowingMentionsSheet = true
        case "todos", "todo-overview": app.openTodoOverview()
        case "journal": app.selectScope(.journal)
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
        case "alias": app.isShowingAliasSheet = true
        case "rename": app.isShowingRenameSheet = true
        case "sync": SettingsWindowController.show(app: app, tab: .sync)
        default: break
        }

        // `SILVICS_SEARCH=<词>` + `SILVICS_SEARCH_SCOPE=all`：取证时预置搜索。
        // 必须放在范围切换之后：`selectScope` 会清空搜索词。
        if let raw = ProcessInfo.processInfo.environment["SILVICS_SEARCH_SCOPE"], raw == "all" {
            app.searchScope = .includingJournal
        }
        if let q = ProcessInfo.processInfo.environment["SILVICS_SEARCH"], !q.isEmpty {
            app.searchQuery = q
        }

        applySyncFlags(app)

        // 取证时先把状态条清掉，截图里不出现「已从 vault 重建…」这类启动提示。
        if path != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { app.clearStatus() }
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
    private static func neutraliseEffectViews(in root: NSView) -> [NSVisualEffectView: (NSVisualEffectView.Material, NSVisualEffectView.BlendingMode, NSVisualEffectView.State)] {
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
    private static func restore(_ saved: [NSVisualEffectView: (NSVisualEffectView.Material, NSVisualEffectView.BlendingMode, NSVisualEffectView.State)]) {
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

    /// `SILVICS_SELFTEST=convert`：把光标放进第一条提及，合成一次 `⌘⇧K`。
    ///
    /// 走的是真实的 `keyDown` → `shouldChangeText` → 正文改写 → 防抖保存链路，
    /// 只是绕开系统键盘事件（自动化按键要「辅助功能」授权）。
    @MainActor
    static func runSelfTest(_ app: AppState) {
        guard ProcessInfo.processInfo.environment["SILVICS_SELFTEST"] == "convert" else { return }
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
}
#endif
