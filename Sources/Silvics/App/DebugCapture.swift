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

        if let keyword = ProcessInfo.processInfo.environment["SILVICS_SELECT"],
           let match = app.summaries.first(where: { $0.title.contains(keyword) }) {
            app.select(match.id)
        }
        switch showPanel {
        case "quickopen": app.isShowingQuickOpen = true
        case "mentions", "mentions-preview":
            app.refreshMentionGroups()
            app.isShowingMentionsSheet = true
        case "settings":
            SettingsWindowController.show(app: app, tab: .appearance)
        case "settings-about":
            SettingsWindowController.show(app: app, tab: .about)
        case "alias": app.isShowingAliasSheet = true
        case "rename": app.isShowingRenameSheet = true
        case "sync": app.isShowingSyncSheet = true
        default: break
        }
        applySyncFlags(app)
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

        if let renderPath = env["SILVICS_RENDER"], !renderPath.isEmpty {
            renderSyncSheet(app, to: renderPath)
        }

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

    /// `SILVICS_RENDER=<png 路径>`：用 `ImageRenderer` 把同步面板离屏画成 PNG。
    ///
    /// 窗口自绘（`dataWithPDF` / `cacheDisplay`）抓不到 SwiftUI 的 Text 层，
    /// 这台机器又没有真实显示会话，所以面板的观感证据走这条离屏渲染。
    @MainActor
    static func renderSyncSheet(_ app: AppState, to path: String) {
        let renderer = ImageRenderer(
            content: SyncSheet(settings: app.syncSettings)
                .environmentObject(app)
                .frame(width: 640, height: 520)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            DebugLog.write("render: 失败")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        DebugLog.write("render: \(path)")
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
