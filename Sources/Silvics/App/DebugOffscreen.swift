#if DEBUG
import AppKit
import SwiftUI

/// 仅 DEBUG：不依赖窗口的主界面离屏渲染。
///
/// 为什么需要：`SILVICS_CAPTURE` 遍历 `NSApp.windows` 里**可见**的窗口再 `cacheDisplay`。
/// 某些会话里 App 起来了但一个可见窗口都没有，于是截图一个文件都不产出，
/// `RootView.onAppear` 里的 `SILVICS_SHOW` 钩子也不执行，界面验收全做不了。
/// 这里自己搭一个 `NSHostingView`（不进窗口），走完布局后栅格化成 PNG。
///
/// 三个环境变量：
/// - `SILVICS_OFFSCREEN=<png>`：输出路径。设了就走离屏通道，渲染完退出。
/// - `SILVICS_OFFSCREEN_NOTE=<标题关键字>`：先选中标题含该关键字的笔记；找不到就取第一篇。
/// - `SILVICS_OFFSCREEN_SIZE=1280x900`：画布点数，默认 1280x900。
/// - `SILVICS_OFFSCREEN_SCALE=2`：每个点画几个像素，默认 2（同 Retina）。写 1 走 `bitmapImageRepForCachingDisplay`。
///
/// `SILVICS_SHOW` 里不依赖窗口的取值（`journal-today`、`lists`、`tables`…）照旧生效；
/// 需要 sheet 的取值在离屏通道跳过，并写进日志。
enum OffscreenCapture {

    /// 离屏通道自己的日志。失败原因只认这个文件，不靠终端回滚。
    static let logPath = "/tmp/silvics-offscreen.log"
    static let defaultSize = NSSize(width: 1280, height: 900)

    /// 强引用住离屏通道用的 AppState，渲染期间不能被回收。
    private static var state: AppState?
    private static var startedAt = Date()
    /// 两个入口（`SilvicsApp.init` 与 `applicationDidFinishLaunching`）都可能会来，只跑一次。
    private static var started = false

    // MARK: - 环境变量

    static var path: String? {
        guard let raw = ProcessInfo.processInfo.environment["SILVICS_OFFSCREEN"],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return raw
    }

    static var noteKeyword: String? {
        guard let raw = ProcessInfo.processInfo.environment["SILVICS_OFFSCREEN_NOTE"],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return raw
    }

    static var pixelScale: Int {
        guard let raw = ProcessInfo.processInfo.environment["SILVICS_OFFSCREEN_SCALE"],
              let value = Int(raw), value == 1 || value == 2 else { return 2 }
        return value
    }

    /// `SILVICS_OFFSCREEN_SIZE=1280x900`。解析失败退回默认，并把原因交回给调用方写日志。
    static func parseSize(_ raw: String?) -> (size: NSSize, warning: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return (defaultSize, nil)
        }
        let parts = raw.lowercased().split(separator: "x").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let width = parts[0], let height = parts[1],
              width >= 200, height >= 200 else {
            return (defaultSize, "SILVICS_OFFSCREEN_SIZE=\"\(raw)\" 解析不出宽高，改用 \(Int(defaultSize.width))x\(Int(defaultSize.height))")
        }
        return (NSSize(width: width, height: height), nil)
    }

    // MARK: - 日志

    /// 同时写 `/tmp/silvics-offscreen.log` 与 stdout。失败不许静默。
    static func log(_ line: String) {
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let text = "\(stamp) \(line)\n"
        print("[offscreen] \(line)")
        let url = URL(fileURLWithPath: logPath)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 入口

    /// 设了 `SILVICS_OFFSCREEN` 就走离屏通道。
    /// `SILVICS_OFFSCREEN_SHEET=new-clip`：不渲染主界面，改成只渲染一张 sheet。
    /// 屏幕锁着的时候窗口通道出不了图，sheet 也得靠这条路取证。
    static var sheetName: String? {
        guard let raw = ProcessInfo.processInfo.environment["SILVICS_OFFSCREEN_SHEET"],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return raw
    }

    /// sheet 画布。没给 `SILVICS_OFFSCREEN_SIZE` 时用它，别拿 1280x900 的白底糊一圈。
    static let sheetSize = NSSize(width: 660, height: 640)

    static var isRequested: Bool { path != nil }

    /// 启动离屏通道。没有 `SILVICS_OFFSCREEN`、或已经启动过时什么都不做。
    @MainActor
    static func startIfRequested() {
        guard !started else { return }
        guard let path else { return }
        started = true
        // 每次启动重写日志：上一次的失败原因不能当这次的证据。
        try? "".write(to: URL(fileURLWithPath: logPath), atomically: true, encoding: .utf8)
        startedAt = Date()

        let visible = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        log("启动离屏通道：pid=\(ProcessInfo.processInfo.processIdentifier) 输出=\(path)")
        log("可见窗口 \(visible.count) 个（\(NSApp.windows.count) 个 window 对象）："
            + (visible.isEmpty ? "窗口通道在这里必然出不了图，改走离屏" : "窗口通道优先，离屏仍独立出图"))

        let parsed = parseSize(ProcessInfo.processInfo.environment["SILVICS_OFFSCREEN_SIZE"])
        if let warning = parsed.warning { log("警告：\(warning)") }
        let canvas = sheetName == nil
            ? parsed.size
            : (ProcessInfo.processInfo.environment["SILVICS_OFFSCREEN_SIZE"] == nil ? sheetSize : parsed.size)
        log("画布 \(Int(canvas.width))x\(Int(canvas.height)) pt，按 \(pixelScale)× 像素渲染"
            + (sheetName.map { "，只渲染 sheet：\($0)" } ?? ""))

        // 离屏用自己的 AppState：它不经过 WindowGroup，拿不到 RootView 里那个。
        applyVaultIfRequested()
        let app = AppState()
        log("vaultPath=\(app.syncSettings.vaultPath) 实际=\(app.repo.vaultURL.path)")
        log("标题=\(app.summaries.map { $0.title }.joined(separator: " | "))")
        if DemoSeeder.isRequested {
            let seeded = DemoSeeder.seedIfEmpty(app)
            if seeded > 0 { log("已播种演示数据：\(seeded) 篇") }
        }
        state = app
        log("库已加载：\(app.summaries.count) 篇（含日记 \(app.journalEntries.count) 篇）")

        // 面板类钩子（`SILVICS_SHOW=quickopen` 等）需要真实窗口才挂得上 sheet，这里跳过。
        DebugCapture.applyShowFlag(app, offscreen: true)
        selectNote(in: app)

        // 给 SwiftUI 与防抖保存一拍时间，再搭视图。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            build(app: app, size: canvas, path: path)
        }
    }


    /// 离屏通道跑在 AppState 之外，`SILVICS_VAULT` 要在建库前写进同步设置，
    /// 否则播种会落到真实 vault。只用于取证。
    private static func applyVaultIfRequested() {
        guard let vault = ProcessInfo.processInfo.environment["SILVICS_VAULT"], !vault.isEmpty else { return }
        var settings = SyncSettings.load()
        settings.vaultPath = vault
        settings.save()
    }

    /// `SILVICS_OFFSCREEN_NOTE`：选中目标笔记。找不到就取第一篇，并写日志。
    @MainActor
    private static func selectNote(in app: AppState) {
        var target: NoteSummary?
        if let keyword = noteKeyword {
            target = app.summaries.first { $0.title.contains(keyword) }
            if target == nil {
                log("SILVICS_OFFSCREEN_NOTE=\"\(keyword)\" 没有匹配的标题，退回第一篇")
            }
        }
        guard let chosen = target ?? app.summaries.first else {
            log("库里一篇笔记都没有，接下来渲染空态")
            return
        }
        // 日记不在「全部」列表里，模块要跟着切，否则导航与列表对不上。
        if chosen.isJournal {
            app.selectModule(.journal)
            app.applyScope(.journal(.all))
        } else if chosen.type == NoteTypes.clipID {
            app.selectModule(.clips)
            app.applyScope(.clip(.all))
        } else {
            app.selectModule(.notes)
            app.applyScope(.note(.all))
        }
        app.select(chosen.id)
        log("选中《\(chosen.title)》id=\(chosen.id) 类型=\(chosen.type)")
    }

    // MARK: - 搭视图

    @MainActor
    private static func build(app: AppState, size: NSSize, path: String) {
        if sheetName != nil { return buildSheet(app: app, size: size, path: path) }
        let hosting = NSHostingView(rootView: RootView().environmentObject(app))
        hosting.frame = NSRect(origin: .zero, size: size)
        log("NSHostingView 已建：\(describe(hosting.frame))，window=\(hosting.window == nil ? "nil（离屏）" : "非空")")
        forceLayout(hosting, label: "第 1 轮")

        // 再跑一轮 RunLoop：SwiftUI 在首次布局后还会按实际尺寸补一次布局，
        // 编辑器（NSTextView）也要等这一轮才把排版算完。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            app.clearStatus()
            forceLayout(hosting, label: "第 2 轮")
            dumpTree(hosting)
            render(hosting, size: size, path: path)
        }
    }

    /// 只渲染 sheet。`NewClipSheet` 自己带固定尺寸，画布比它大就居中留白。
    @MainActor
    private static func buildSheet(app: AppState, size: NSSize, path: String) {
        // 不在窗口里时 `Color.primary` 解不出外观，字会画成白底白字。锁到浅色。
        let root = ZStack {
            Color(nsColor: .windowBackgroundColor)
            NewClipSheet().environmentObject(app)
        }
        let sheet = NSHostingView(rootView: root)
        sheet.appearance = NSAppearance(named: .aqua)
        sheet.frame = NSRect(origin: .zero, size: size)
        log("sheet 离屏：\(sheetName ?? "?")，画布 \(describe(sheet.frame))")
        forceLayout(sheet, label: "第 1 轮")

        // 文件导入、抓取、整理都是异步的，要等面板自己走到预览态再拍。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            app.clearStatus()
            forceLayout(sheet, label: "第 2 轮")
            dumpTree(sheet)
            render(sheet, size: size, path: path)
        }
    }

    /// 把布局推到底，并把「布局到底完成没有」的量写进日志。
    @MainActor
    private static func forceLayout(_ view: NSView, label: String) {
        var started = Date()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        reloadTables(in: view)
        let firstPass = Date().timeIntervalSince(started)

        var parts = ["frame=\(describe(view.frame))", "子视图 \(countViews(view)) 个"]
        if let editor = largestTextView(in: view) {
            started = Date()
            if let manager = editor.textLayoutManager {
                manager.ensureLayout(for: manager.documentRange)
            }
            editor.layoutSubtreeIfNeeded()
            parts.append("编辑区=\(describe(editor.frame)) 正文 \(editor.string.count) 字"
                         + " 排版 \(Int(Date().timeIntervalSince(started) * 1000))ms")
        } else {
            parts.append("编辑区=没有 NSTextView（空态或布局没跑）")
        }
        parts.append("首轮 layoutSubtreeIfNeeded \(Int(firstPass * 1000))ms")
        parts.append("累计 \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
        log("\(label)布局：\(parts.joined(separator: "，"))")
    }

    /// 列表（侧栏）是 AppKit 的表格视图，只有进窗口才会自己建行。
    /// 离屏时手动 `reloadData` 一次，让它按当前可见区域把行建出来。
    @MainActor
    private static func reloadTables(in view: NSView) {
        func walk(_ node: NSView) {
            if let table = node as? NSTableView {
                table.reloadData()
                table.noteNumberOfRowsChanged()
                table.layoutSubtreeIfNeeded()
                // 行视图同样是「有窗口才建」：手动按行号要一遍，行才会被创建并铺开。
                // 行高由代理在铺开时才报出来，所以「建行 → tile → 重算行高 → tile」要两轮，
                // 否则多行内容的行会按默认 30 排，第二行文字压到下一行上。
                for _ in 0..<2 {
                    for row in 0..<table.numberOfRows {
                        _ = table.rowView(atRow: row, makeIfNecessary: true)
                        for column in 0..<max(table.numberOfColumns, 1) {
                            _ = table.view(atColumn: column, row: row, makeIfNecessary: true)
                        }
                    }
                    table.tile()
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<max(table.numberOfRows, 1)))
                    table.layoutSubtreeIfNeeded()
                }
                table.tile()
                let heights = (0..<table.numberOfRows).map { Int(table.rect(ofRow: $0).height) }
                log("列表 \(String(describing: type(of: table)))：\(table.numberOfRows) 行，"
                    + "子视图 \(table.subviews.count) 个，行高 \(heights)")
            }
            for sub in node.subviews { walk(sub) }
        }
        walk(view)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    /// `SILVICS_OFFSCREEN_DUMP=1`：把视图树写进日志。用来排查「某块没画出来」。
    @MainActor
    static func dumpTree(_ view: NSView) {
        guard ProcessInfo.processInfo.environment["SILVICS_OFFSCREEN_DUMP"] == "1" else { return }
        var lineCount = 0
        func walk(_ node: NSView, depth: Int) {
            guard lineCount < 400 else { return }
            lineCount += 1
            var extra = ""
            if let table = node as? NSTableView {
                extra += " 表格行=\(table.numberOfRows) 列=\(table.numberOfColumns)"
            }
            if let scroll = node as? NSScrollView {
                extra += " document=\(scroll.documentView.map { String(describing: type(of: $0)) } ?? "nil")"
                if let doc = scroll.documentView {
                    extra += " 文档子视图=\(doc.subviews.count) 尺寸=\(describe(doc.frame))"
                }
            }
            log("\(String(repeating: "  ", count: depth))\(String(describing: type(of: node))) "
                + "\(describe(node.frame))"
                + (node.isHidden ? " hidden" : "")
                + (node.alphaValue < 1 ? " alpha=\(node.alphaValue)" : "")
                + (node.layer == nil ? " 无 layer" : "")
                + extra)
            for sub in node.subviews { walk(sub, depth: depth + 1) }
        }
        walk(view, depth: 0)
    }

    // MARK: - 栅格化

    @MainActor
    private static func render(_ view: NSView, size: NSSize, path: String) {
        let bounds = NSRect(origin: .zero, size: size)
        // 选中行的材质由 WindowServer 合成，离屏栅格化会画成黑块；改成普通材质再画。
        let restored = DebugCapture.neutraliseEffectViews(in: view)
        view.layoutSubtreeIfNeeded()

        var failure: String?
        var rep: NSBitmapImageRep?
        if pixelScale == 1 {
            rep = view.bitmapImageRepForCachingDisplay(in: bounds)
            if rep == nil { failure = "bitmapImageRepForCachingDisplay 返回 nil" }
        } else {
            rep = scaledBitmap(size: size, scale: pixelScale)
            if rep == nil { failure = "\(pixelScale)× NSBitmapImageRep 建不出来" }
        }
        if let rep {
            view.cacheDisplay(in: bounds, to: rep)
        }
        DebugCapture.restore(restored)

        guard let rep else {
            log("渲染失败：\(failure ?? "未知原因")")
            finish(code: 1)
            return
        }

        if let blank = blankVerdict(rep) { log("警告：\(blank)") }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            log("渲染失败：NSBitmapImageRep 转 PNG 失败（\(rep.pixelsWide)x\(rep.pixelsHigh)）")
            finish(code: 1)
            return
        }

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
        } catch {
            log("渲染失败：写 \(path) 出错 —— \(error.localizedDescription)")
            finish(code: 1)
            return
        }

        log("已写出 \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh) 像素，\(data.count) 字节"
            + "（\(Int(size.width))x\(Int(size.height)) pt ×\(pixelScale)）")
        finish(code: 0)
    }

    /// 指定倍数建位图。`rep.size` 设成点数，`cacheDisplay` 就会按倍数放大画。
    private static func scaledBitmap(size: NSSize, scale: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        return rep
    }

    /// 采样看是不是单色。单色说明布局或绘制没生效 —— 这种情况要写成失败原因，不能当成功。
    static func blankVerdict(_ rep: NSBitmapImageRep) -> String? {
        guard let data = rep.bitmapData else { return "取不到位图数据" }
        let bytesPerPixel = rep.bitsPerPixel / 8
        guard bytesPerPixel >= 3, rep.bytesPerRow > 0 else { return nil }
        var seen = Set<UInt32>()
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                let offset = y * rep.bytesPerRow + x * bytesPerPixel
                let key = (UInt32(data[offset]) << 16)
                    | (UInt32(data[offset + 1]) << 8)
                    | UInt32(data[offset + 2])
                seen.insert(key)
                if seen.count > 24 { return nil }
                x += 13
            }
            y += 13
        }
        return "整张图只有 \(seen.count) 种采样色，疑似空白（布局或绘制没生效）"
    }

    // MARK: - 收尾

    /// 落库后退出：离屏通道是一次性进程，留着也不会再有窗口。
    @MainActor
    private static func finish(code: Int32) {
        state?.flushPendingSave()
        log("结束：退出码 \(code)，总耗时 \(Int(Date().timeIntervalSince(startedAt) * 1000))ms")
        exit(code)
    }

    // MARK: - 小工具

    private static func describe(_ rect: NSRect) -> String {
        String(format: "%.0fx%.0f@(%.0f,%.0f)", rect.width, rect.height, rect.minX, rect.minY)
    }

    private static func countViews(_ view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + countViews($1) }
    }

    private static func largestTextView(in view: NSView) -> NSTextView? {
        var found: NSTextView?
        func walk(_ view: NSView) {
            if let textView = view as? NSTextView,
               textView.frame.width * textView.frame.height > (found?.frame.width ?? 0) * (found?.frame.height ?? 0) {
                found = textView
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(view)
        return found
    }
}
#endif
