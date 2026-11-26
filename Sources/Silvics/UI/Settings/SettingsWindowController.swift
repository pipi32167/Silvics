import AppKit
import SwiftUI

/// 设置窗口。
///
/// 用 `NSWindowController` 而不是 SwiftUI `Settings` scene：`.fullSizeContentView`
/// 必须在建窗时给出，macOS 26 才会渲染圆角与玻璃质感。菜单「Silvics → 设置…」（`⌘,`）
/// 调 `SettingsWindowController.show()`。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private var app: AppState?

    static func show(app: AppState, tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }
        if let shared {
            shared.app = app
            shared.showWindow(nil)
            return
        }
        let controller = SettingsWindowController(app: app)
        shared = controller
        controller.showWindow(nil)
    }

    private init(app: AppState) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow() {
        guard let window, let app else { return }
        window.title = "设置"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsView().environmentObject(app)
        )
        // 内容视图装好后再定尺寸：NSHostingController 会按 SwiftUI 的 fitting size 缩窗。
        window.setFrameAutosaveName("SilvicsSettingsWindow")
        window.contentMinSize = NSSize(width: 620, height: 520)
        window.minSize = NSSize(width: 620, height: 520)
        window.setContentSize(Self.debugContentSize)
        window.center()
    }

    /// 取证用：`SILVICS_SETTINGS_SIZE=680x1200` 把设置窗撑高，好一屏截完长表单。
    private static var debugContentSize: NSSize {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SILVICS_SETTINGS_SIZE"] {
            let parts = raw.lowercased().split(separator: "x")
            if parts.count == 2,
               let width = Double(parts[0]), let height = Double(parts[1]),
               width >= 620, height >= 520 {
                return NSSize(width: width, height: height)
            }
        }
        #endif
        return NSSize(width: 680, height: 600)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
