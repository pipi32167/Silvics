import AppKit
import SwiftUI

// MARK: - 文本视图

/// 待办行左侧的复选框。只负责外观与点击，位置由 `EditorTextView` 排。
///
/// 不用 `NSTextAttachment`：附件会改写正文（实测 197 → 177 字），
/// 而这里只让浮层动，正文一个字符不动（S39 / S40）。
///
/// 也不用 `setButtonType(.switch)` + `isBordered = false`：本机实测它只画出
/// 一块淡灰圆角矩形，没有边框，勾选态也只是一根对钩，难认。
/// 改用 SF Symbols：未完成 `square`，已完成 `checkmark.square.fill`。
final class TodoCheckbox: NSButton {

    /// 该行行首的字符偏移。点击时按它定位待办。
    var lineLocation: Int = 0

    /// 勾选状态。只换图与色，不改正文。
    var isChecked: Bool = false {
        didSet {
            guard oldValue != isChecked else { return }
            applyAppearance()
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: ListLayout.checkboxSize, height: ListLayout.checkboxSize))
        setButtonType(.momentaryChange)
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        setAccessibilityLabel("勾选待办")
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func applyAppearance() {
        let name = isChecked ? "checkmark.square.fill" : "square"
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        contentTintColor = isChecked ? Theme.linkText : Theme.secondaryText
        state = isChecked ? .on : .off
        setAccessibilityValue(isChecked ? "已完成" : "未完成")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 编辑用的 NSTextView。
///
/// 只加两件事：⌘ 点击打开引用、Esc 关闭补全。
/// 其余行为全部交给 AppKit，这是选原生技术栈的收益。
final class EditorTextView: NSTextView {

    /// 点击的引用目标标题。由 Coordinator 提供解析。
    var onOpenWikiLink: ((String) -> Void)?
    /// 已解析的引用区间与目标。用于点击命中判定。
    var wikiHitRects: [(NSRange, String)] = [] {
        didSet {
            if !Self.sameWikiRects(oldValue, wikiHitRects) {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    /// 当前笔记的未链接提及区间。`⌘⇧K` 按光标命中判定。
    var mentionRanges: [NSRange] = []
    /// Esc 时先通知补全面板。
    var onEscape: (() -> Bool)?
    /// `⌘⇧K`：把光标所在提及转成引用。返回 true 表示已处理。
    var onConvertMention: (() -> Bool)?

    /// 撤销/重做交给 `Coordinator` 的自管撤销栈（issue #35）。
    ///
    /// `NSTextView` 自己不实现 `undo:`，不接管就会沿响应链落到窗口那个共享的
    /// `undoManager` 上 —— 那个栈换笔记也不换，会把上一篇的动作执行到这一篇。
    var onUndo: (() -> Bool)?
    var onRedo: (() -> Bool)?
    /// 菜单项可用状态：撤销栈里有没有东西。
    var canUndoAction: (() -> Bool)?
    var canRedoAction: (() -> Bool)?

    @objc func undo(_ sender: Any?) {
        _ = onUndo?()
    }

    @objc func redo(_ sender: Any?) {
        _ = onRedo?()
    }

    /// 菜单项的可用状态由本篇笔记的栈决定。
    ///
    /// 两个方法都要：`NSMenu` 走 `validateMenuItem:`，工具栏与快捷键走
    /// `validateUserInterfaceItem(_:)`。少一个就会出现「能点但点了没反应」。
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return canUndoAction?() ?? false
        case #selector(redo(_:)):
            return canRedoAction?() ?? false
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            return canUndoAction?() ?? false
        case #selector(redo(_:)):
            return canRedoAction?() ?? false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    /// 任何一次正文改动开始前通知：记下「改之前的光标位置」与这次插入的文字。
    ///
    /// 插入文字要看 `replacementString`，不能靠「改完比改前长多少」——
    /// 在段落中间插入时，正文末尾那几个字跟这次插入无关。
    var onWillChange: ((NSRange, String?) -> Void)?

    override func shouldChangeText(
        in affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed { onWillChange?(selectedRange(), replacementString) }
        return allowed
    }

    /// 代码块区间（含首尾围栏行）。块底色由 `drawBackground(in:)` 整块画。
    var codeBlockRanges: [NSRange] = [] {
        didSet {
            if oldValue != codeBlockRanges { needsDisplay = true }
        }
    }

    /// 当前正文的列表行。项目符号 / 序号 / 待办复选框都按它画。
    ///
    /// 与 `listMarkersLength` 一起构成不变量：这份标记必须是从当前正文解析出来的。
    /// 组字期间正文变了而标记没重算时，按旧偏移摆浮层会把复选框摆到别的行上（issue #49）。
    var listMarkers: [ListMarker] = [] {
        didSet {
            if oldValue != listMarkers { needsDisplay = true }
            relayoutTodoCheckboxes()
        }
    }

    /// `listMarkers` 是解析自多长的正文。`relayoutTodoCheckboxes` 用它挡住过期偏移。
    private(set) var listMarkersLength: Int = 0

    /// 换一份标记，同时记下它是从哪份正文解析出来的。
    func setListMarkers(_ markers: [ListMarker], parsedFrom text: String) {
        listMarkersLength = (text as NSString).length
        listMarkers = markers
    }

    /// 标记与当前正文是否还能对上：长度一致，且每行首偏移确实落在段落起始位置。
    ///
    /// 只比长度也够挡住组字这种情况，但同长度改写（选中后重打一个词）不会变长度，
    /// 多查一次「行首是不是段落起点」就能把这类错位一起挡掉。
    private var listMarkersMatchCurrentText: Bool {
        let ns = string as NSString
        guard listMarkersLength == ns.length else { return false }
        for marker in listMarkers {
            let location = marker.markerRange.location
            guard location >= 0, location < ns.length else { return false }
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.location == location else { return false }
        }
        return true
    }

    /// 光标所在段落。这一段露源码：标记不压宽，也不画符号与复选框（S37 / S40）。
    var caretParagraph: NSRange? {
        didSet {
            if oldValue != caretParagraph {
                needsDisplay = true
                relayoutTodoCheckboxes()
            }
        }
    }

    /// 引用行前缀与层级（画左侧竖线）。
    var quoteMarks: [QuoteMark] = [] {
        didSet {
            if oldValue != quoteMarks { needsDisplay = true }
        }
    }

    /// 源码模式：整篇露源码（对齐 Typora 的 ⌘/）。
    ///
    /// 块级标记改成「永不露」之后，必须留一个能看见、能直接改标记的出口：
    /// 换标题级别、改列表符号、动表格分隔行都走这里，而不是靠光标进出行。
    var showsSource: Bool = false {
        didSet {
            guard oldValue != showsSource else { return }
            needsDisplay = true
            // 复选框在源码模式下不画、切回来要补上（不能只靠 needsDisplay 等下一次布局）。
            relayoutTodoCheckboxes()
        }
    }

    /// 表格块（画网格线，对齐 Typora 的「真表格」观感）。
    var tableBlocks: [TableBlock] = [] {
        didSet {
            needsDisplay = true
        }
    }

    /// 已画出的复选框数量（测试与自检用）。
    var todoCheckboxCount: Int { todoCheckboxes.count }

    /// 已画出的复选框位置，按行首升序。
    var todoCheckboxFrames: [NSRect] {
        todoCheckboxes.keys.sorted().map { todoCheckboxes[$0]!.frame }
    }

    /// 已画出的复选框：行首偏移、勾选态、位置。测试按它对账（issue #49）。
    var todoCheckboxItems: [(location: Int, checked: Bool, frame: NSRect)] {
        todoCheckboxes.keys.sorted().map { key in
            let box = todoCheckboxes[key]!
            return (key, box.isChecked, box.frame)
        }
    }

    // MARK: 待办复选框浮层

    /// 待办行左侧的可点方框。键是行首偏移，位置每次重排。
    private var todoCheckboxes: [Int: TodoCheckbox] = [:]
    private var isLayingOutCheckboxes = false
    private var scrollObserver: NSObjectProtocol?
    /// ⌘ 变化的监听。挂在本进程的事件流上，不依赖第一响应者（issue #8）。
    private var modifierMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installScrollObserver()
        installModifierMonitor()
        // 新视图进窗口时按当前 ⌘ 状态把 cursor rect 注册一次。
        window?.invalidateCursorRects(for: self)
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    /// 监听 ⌘ 的按下与松开。
    ///
    /// 为什么不用 `flagsChanged`：它只投给第一响应者。换笔记时
    /// `NoteEditorView(...).id(note.id)` 会把整块视图换新，新视图不一定拿到焦点，
    /// 于是「悬停在引用上按 ⌘」就没有反应。窗口级监听不受焦点影响。
    private func installModifierMonitor() {
        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }
        guard window != nil else { return }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.refreshCursorForModifiers()
            return event
        }
    }

    /// 滚动时重新定位方框。`NSTextView` 是滚动视图的 documentView，
    /// 自己不动，是 clipView 的 bounds 在变，所以监听 clipView。
    private func installScrollObserver() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.relayoutTodoCheckboxes()
        }
    }

    override func layout() {
        super.layout()
        relayoutTodoCheckboxes()
    }

    /// 按第一视觉行的位置重排复选框：可见范围内才建控件。
    ///
    /// 前置条件：`listMarkers` 必须来自当前正文。组字期间正文一变、偏移就作废，
    /// 此时按偏移量位置会把别的行的复选框画到组字这一行，勾选态也跟着取错（issue #49）。
    private func relayoutTodoCheckboxes() {
        guard !isLayingOutCheckboxes else { return }
        guard listMarkersMatchCurrentText else { return }
        isLayingOutCheckboxes = true
        defer { isLayingOutCheckboxes = false }

        let wanted = showsSource ? [] : ListLayout.checkboxTodos(listMarkers, caretParagraph: caretParagraph)
        let visible = visibleRect.insetBy(dx: 0, dy: -60)
        var keep: Set<Int> = []

        for marker in wanted {
            guard let frame = firstLineFrame(forCharacterAt: marker.markerRange.location) else { continue }
            let box = NSRect(
                x: textContainerOrigin.x + frame.minX - ListLayout.gutter + 2,
                y: textContainerOrigin.y + frame.minY
                    + (frame.height - ListLayout.checkboxSize) / 2,
                width: ListLayout.checkboxSize,
                height: ListLayout.checkboxSize
            )
            guard box.intersects(visible) else { continue }
            keep.insert(marker.markerRange.location)

            let checkbox = todoCheckboxes[marker.markerRange.location]
                ?? makeTodoCheckbox(at: marker.markerRange.location)
            checkbox.lineLocation = marker.markerRange.location
            checkbox.isChecked = marker.kind == .todo(checked: true)
            if checkbox.frame != box { checkbox.frame = box }
        }

        for (key, checkbox) in todoCheckboxes where !keep.contains(key) {
            checkbox.removeFromSuperview()
            todoCheckboxes.removeValue(forKey: key)
        }
    }

    private func makeTodoCheckbox(at lineLocation: Int) -> TodoCheckbox {
        let checkbox = TodoCheckbox()
        checkbox.lineLocation = lineLocation
        checkbox.target = self
        checkbox.action = #selector(todoCheckboxClicked(_:))
        addSubview(checkbox)
        todoCheckboxes[lineLocation] = checkbox
        return checkbox
    }

    @objc private func todoCheckboxClicked(_ sender: TodoCheckbox) {
        toggleTodo(at: sender.lineLocation)
    }

    /// 勾选 / 取消勾选：改正文的 `[ ]` ↔ `[x]`，走 `shouldChangeText` + `didChangeText`，可撤销（S39）。
    @discardableResult
    func toggleTodo(at location: Int) -> Bool {
        guard isEditable else { return false }
        guard let storage = textStorage else { return false }
        guard let range = MarkdownStyler.todoCheckRange(in: string, at: location) else { return false }
        let current = (string as NSString).substring(with: range)
        let next = (current == "x" || current == "X") ? " " : "x"
        guard shouldChangeText(in: range, replacementString: next) else { return false }
        storage.replaceCharacters(in: range, with: next)
        didChangeText()
        // 自己先把标记表刷新一遍：勾完立刻换勾选外观，不依赖外部是否重排。
        // `didChangeText` 之后 Coordinator 还会整体 restyle 一次，这次只是让浮层不等它。
        setListMarkers(MarkdownStyler.listMarkers(in: string), parsedFrom: string)
        return true
    }

    // MARK: 列表与引用的自绘

    /// 一个段落第一视觉行在容器坐标里的 frame。
    private func firstLineFrame(forCharacterAt index: Int) -> NSRect? {
        guard let manager = textLayoutManager,
              let storage = textStorage, storage.length > 0 else { return nil }
        let ns = string as NSString
        let clamped = min(max(0, index), ns.length - 1)
        let paragraph = ns.paragraphRange(for: NSRange(location: clamped, length: 0))
        let document = manager.documentRange
        guard let start = manager.location(document.location, offsetBy: paragraph.location),
              let end = manager.location(start, offsetBy: paragraph.length),
              let range = NSTextRange(location: start, end: end) else { return nil }
        manager.ensureLayout(for: range)
        var top: NSRect?
        manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            if top == nil || frame.minY < top!.minY { top = frame }
            return true
        }
        return top
    }

    /// 全部视觉行在容器坐标里的纵向范围（引用竖线用）。
    private func verticalExtent(of range: NSRange) -> (top: CGFloat, bottom: CGFloat)? {
        guard let manager = textLayoutManager, let storage = textStorage,
              storage.length > 0, range.length > 0 else { return nil }
        let document = manager.documentRange
        guard let start = manager.location(document.location, offsetBy: range.location),
              let end = manager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        manager.ensureLayout(for: textRange)
        var top = CGFloat.greatestFiniteMagnitude
        var bottom = -CGFloat.greatestFiniteMagnitude
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            top = min(top, frame.minY)
            bottom = max(bottom, frame.maxY)
            return true
        }
        guard bottom > top else { return nil }
        return (top, bottom)
    }

    /// 项目符号、有序序号、引用竖线。
    private func drawListDecorations() {
        guard !showsSource, textStorage?.length ?? 0 > 0 else { return }
        let origin = textContainerOrigin
        let visible = visibleRect

        for mark in quoteMarks {
            guard let extent = verticalExtent(of: mark.blockRange) else { continue }
            // 竖线挂在正文左缘左侧：第 1 级与标题同左缘，深一级跟着缩进走（issue #50）。
            let textLeft = origin.x + 5 + ListLayout.offset(level: mark.level)
            let bar = NSRect(
                x: textLeft - QuoteLayout.barInset,
                y: origin.y + extent.top + 1,
                width: QuoteLayout.barWidth,
                height: max(0, extent.bottom - extent.top - 2)
            )
            guard bar.intersects(visible) else { continue }
            Theme.quoteBar.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }

        for marker in ListLayout.markersToRender(listMarkers, caretParagraph: caretParagraph) {
            guard let frame = firstLineFrame(forCharacterAt: marker.markerRange.location) else { continue }
            let box = frame.offsetBy(dx: origin.x, dy: origin.y)
            guard box.intersects(visible) else { continue }
            switch marker.kind {
            case .unordered:
                drawBullet(level: marker.level, box: box)
            case .ordered(let number):
                drawOrderedNumber(number, box: box)
            case .todo:
                break // 复选框是 NSButton 浮层
            }
        }
    }

    /// 项目符号。按层级换形状：一级实心圆、二级空心圆、三级小方块（issue #50）。
    ///
    /// 位置挂在 `ListLayout.gutter` 里，正文因此与标题同左缘（第 1 级）。
    private func drawBullet(level: Int, box: NSRect) {
        let x = box.minX - 10
        let y = box.midY
        Theme.secondaryText.setFill()
        switch level {
        case 1:
            let diameter = ListLayout.bulletDiameter
            NSBezierPath(ovalIn: NSRect(
                x: x - diameter / 2, y: y - diameter / 2,
                width: diameter, height: diameter
            )).fill()
        case 2:
            let diameter = ListLayout.bulletDiameter
            let ring = NSBezierPath(ovalIn: NSRect(
                x: x - diameter / 2, y: y - diameter / 2,
                width: diameter, height: diameter
            ))
            ring.lineWidth = 1
            ring.stroke()
        default:
            let side: CGFloat = 4
            NSBezierPath(rect: NSRect(
                x: x - side / 2, y: y - side / 2, width: side, height: side
            )).fill()
        }
    }

    /// 有序列表的序号。**用原文序号，不重排**（S38）。
    private func drawOrderedNumber(_ number: Int, box: NSRect) {
        let label = "\(number)." as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.font(ofSize: Theme.bodySize * 0.92, weight: .regular),
            .foregroundColor: Theme.secondaryText,
        ]
        let size = label.size(withAttributes: attributes)
        let rect = NSRect(
            x: box.minX - 8 - size.width,
            y: box.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        label.draw(in: rect, withAttributes: attributes)
    }

    /// 代码块整块底色。
    ///
    /// 为什么不用 `.backgroundColor`：本视图是 TextKit 2（`usingTextLayoutManager: true`），
    /// 段落属性里的背景只按字形游程上色，于是每行只得到一条与文字等宽的浅灰条，
    /// 行首缩进与不可见的反引号变成一个个短灰块，行与行之间断开（H01 视觉判据不通过）。
    /// 这里按块自绘：横向铺满整个文本列，纵向从首行顶到最后一行底，中间不留缝。
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCodeBlockBackgrounds()
        drawTableGrid()
        drawListDecorations()
    }

    private func drawCodeBlockBackgrounds() {
        guard !codeBlockRanges.isEmpty,
              let manager = textLayoutManager,
              let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return }

        let origin = textContainerOrigin
        let left = origin.x
        let width = container.size.width
        guard width > 0 else { return }

        let document = manager.documentRange
        var paths: [NSBezierPath] = []
        for range in codeBlockRanges {
            guard range.length > 0,
                  let start = manager.location(document.location, offsetBy: range.location),
                  let end = manager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            manager.ensureLayout(for: textRange)

            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                top = min(top, frame.minY)
                bottom = max(bottom, frame.maxY)
                return true
            }
            guard bottom > top else { continue }

            // 上下各留 4pt 呼吸，左右铺满整列。上下边距不加到相邻块之间，直接贴块边界算。
            let box = NSRect(
                x: left,
                y: top + origin.y - 4,
                width: width,
                height: (bottom - top) + 8
            )
            paths.append(NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6))
        }
        guard !paths.isEmpty else { return }
        Theme.codeBackground.setFill()
        for path in paths { path.fill() }
    }

    /// 表格网格线。
    ///
    /// 只画线，不改正文：pipe 字符仍在（横向对齐靠它算 kern），渲染态被染成透明，
    /// 线条由这里补上。竖线位置取第一行（表头）的 pipe 位置，各行的 pipe 已被 kern 对齐到同一列。
    private func drawTableGrid() {
        guard !showsSource, !tableBlocks.isEmpty,
              let manager = textLayoutManager,
              let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        var segments: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []  // x1, y1, x2, y2

        for block in tableBlocks {
            guard block.rows.count >= 2 else { continue }
            var rowTops: [CGFloat] = []
            var rowBottoms: [CGFloat] = []
            for row in block.rows {
                guard let extent = verticalExtent(of: row.contentRange) else { continue }
                rowTops.append(origin.y + extent.top)
                rowBottoms.append(origin.y + extent.bottom)
            }
            guard let top = rowTops.min(), let bottom = rowBottoms.max() else { continue }

            // 竖线：取第一行的 pipe。
            guard let firstRow = block.rows.first, !firstRow.pipes.isEmpty else { continue }
            let xs = firstRow.pipes.compactMap { xPosition(ofCharacterAt: $0.location) }
            guard let left = xs.first, let right = xs.last, right > left else { continue }
            for x in xs {
                segments.append((x, top, x, bottom))
            }
            // 行线：块顶 + 每行底（含表头底，正好当表头分隔线）。
            segments.append((left, top, right, top))
            for y in rowBottoms {
                segments.append((left, y, right, y))
            }
        }
        guard !segments.isEmpty else { return }
        Theme.tableBorder.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for segment in segments {
            path.move(to: NSPoint(x: segment.0, y: segment.1))
            path.line(to: NSPoint(x: segment.2, y: segment.3))
        }
        path.stroke()
    }

    /// 某个字符在容器坐标里的 x（表格竖线定位用）。
    private func xPosition(ofCharacterAt index: Int) -> CGFloat? {
        guard let manager = textLayoutManager, let storage = textStorage,
              index >= 0, index < storage.length else { return nil }
        guard let location = manager.location(manager.documentRange.location, offsetBy: index),
              let fragment = manager.textLayoutFragment(for: location) else { return nil }
        let ns = string as NSString
        let paragraphStart = ns.paragraphRange(for: NSRange(location: index, length: 0)).location
        var base = 0
        for lineFragment in fragment.textLineFragments {
            let length = lineFragment.characterRange.length
            if index >= paragraphStart + base, index < paragraphStart + base + length {
                let point = lineFragment.locationForCharacter(at: index - paragraphStart - base)
                return textContainerOrigin.x + fragment.layoutFragmentFrame.minX + point.x
            }
            base += length
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let target = wikiTarget(at: event) {
            onOpenWikiLink?(target)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: 指针形状（issue #8）

    /// 按住 ⌘ 时，落在引用上的指针变成手型，提示「可跳转」。
    override func resetCursorRects() {
        super.resetCursorRects()
        guard currentCursorState().registersHandRects else { return }
        for rect in wikiLinkCursorRects() {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    /// 有焦点时 `flagsChanged` 也会到（监听之外的兜底）。
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        #if DEBUG
        debugFlagsChangedCount += 1
        #endif
        refreshCursorForModifiers()
    }

    /// ⌘ 只是按下 / 松开、鼠标不动时，AppKit 不会重算光标矩形，这里手动推一次。
    ///
    /// 每次都按当前状态算，不看历史，因此视图重建、刚进窗口、焦点在别处都不会漏。
    func refreshCursorForModifiers() {
        guard let window else { return }
        let state = currentCursorState()
        if ProcessInfo.processInfo.environment["SILVICS_CURSOR_TRACE"] != nil {
            DebugLog.write("[cursor-refresh] cmd=\(state.commandHeld) over=\(state.overLink)"
                + " 指针=\(state.cursor === NSCursor.pointingHand ? "hand" : (state.cursor === NSCursor.iBeam ? "ibeam" : "nil"))"
                + " 系统修饰键=\(NSEvent.modifierFlags.contains(.command))")
        }
        window.invalidateCursorRects(for: self)
        if let cursor = state.cursor { cursor.set() }
    }

    /// 当前指针形状的两个输入：⌘ 状态与指针位置。
    ///
    /// 两个输入都能被测试与取证钩子替换（`debugModifierOverride` / `debugPointerOverride`），
    /// 这样不必真的按住键盘也能验证判定。
    func currentCursorState() -> WikiCursorState {
        let flags = debugModifierOverride ?? NSEvent.modifierFlags
        let point = debugPointerOverride ?? pointerLocation()
        let overLink = bounds.contains(point) && wikiTarget(at: point) != nil
        return WikiCursorState(commandHeld: flags.contains(.command), overLink: overLink)
    }

    private func pointerLocation() -> NSPoint {
        guard let window else { return NSPoint(x: -1, y: -1) }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// 每个引用区间按视觉行切开的矩形（视图坐标）。
    ///
    /// `resetCursorRects` 用它注册手型指针；测试直接量这些矩形。
    func wikiLinkCursorRects() -> [NSRect] {
        guard let manager = textLayoutManager,
              let storage = textStorage, storage.length > 0 else { return [] }
        let document = manager.documentRange
        let origin = textContainerOrigin
        var out: [NSRect] = []
        for (range, _) in wikiHitRects {
            guard range.length > 0,
                  range.location >= 0,
                  range.location + range.length <= storage.length,
                  let start = manager.location(document.location, offsetBy: range.location),
                  let end = manager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            manager.ensureLayout(for: textRange)
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                // 空片段不加矩形，否则鼠标落在行尾也会变手型。
                guard frame.width > 1 else { return true }
                out.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                return true
            }
        }
        return out
    }

    /// 是否已挂上 ⌘ 监听。换笔记重建视图后必须重新挂上。
    var isObservingModifierChanges: Bool { modifierMonitor != nil }

    /// 取证 / 测试用：替换系统 ⌘ 状态，不必真的按键。
    ///
    /// 平时是 `nil`，判定走 `NSEvent.modifierFlags`。测试要断言的正是「判定只看当前输入」。
    var debugModifierOverride: NSEvent.ModifierFlags?
    /// 取证 / 测试用：替换指针位置。
    var debugPointerOverride: NSPoint?

    #if DEBUG
    /// 收到了多少次 `flagsChanged`。只用于取证。
    var debugFlagsChangedCount = 0

    /// 仅取证：报告「鼠标是否停在引用上、当前指针是不是手型」。
    ///
    /// 指针形状截不进图（`screencapture -C` 在本机不画光标），只能读运行时的真值。
    func debugCursorReport() -> String {
        guard let window else { return "no-window" }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let overLink = bounds.contains(point) && wikiTarget(at: point) != nil
        let cursor: String
        if NSCursor.current === NSCursor.pointingHand {
            cursor = "hand"
        } else if NSCursor.current === NSCursor.iBeam {
            cursor = "ibeam"
        } else {
            cursor = "other"
        }
        let hits = wikiHitRects.map { "\($0.0.location)+\($0.0.length)" }.joined(separator: ",")
        let isFirstResponder = window.firstResponder === self
        return "cmd=\(NSEvent.modifierFlags.contains(.command)) overLink=\(overLink)"
            + " fr=\(isFirstResponder) flags=\(debugFlagsChangedCount)"
            + " cursor=\(cursor) rects=\(wikiLinkCursorRects().count)"
            + " point=\(Int(point.x)),\(Int(point.y)) bounds=\(Int(bounds.width))x\(Int(bounds.height))"
            + " hits=\(hits)"
    }
    #endif

    private static func sameWikiRects(_ a: [(NSRange, String)], _ b: [(NSRange, String)]) -> Bool {
        guard a.count == b.count else { return false }
        for (lhs, rhs) in zip(a, b) where lhs.0 != rhs.0 || lhs.1 != rhs.1 { return false }
        return true
    }

    /// 光标停在自动补出的空 `[]` 中间时退格，两个一起删。
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        let ns = string as NSString
        if isEditable, selection.length == 0, selection.location >= 1, selection.location < ns.length,
           ns.character(at: selection.location - 1) == 0x5B,   // [
           ns.character(at: selection.location) == 0x5D {      // ]
            let pair = NSRange(location: selection.location - 1, length: 2)
            guard shouldChangeText(in: pair, replacementString: "") else { return }
            textStorage?.replaceCharacters(in: pair, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: pair.location, length: 0))
            return
        }
        super.deleteBackward(sender)
    }

    // MARK: 括号配对（issue #8）

    /// 输入法正在组字。
    ///
    /// 从第一次 `setMarkedText` 起为真，到 `unmarkText` / 上屏落回 false。
    /// 不能只看 `hasMarkedText()`：AppKit 在替换组合串的那一瞬间会短暂清掉 marked range，
    /// 那一瞬读到的是 false，于是组字被当成普通输入重排一遍（issue #49）。
    private(set) var isComposingText = false

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        isComposingText = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        // 组合串本身就是正文的一部分：浮层位置要跟着它走，属性一律不动（issue #49）。
        // 不能等 `textDidChange`：组字是「进行中的编辑」，实测它不改正文通知（同 I01）。
        refreshDecorationsDuringComposition()
    }

    override func unmarkText() {
        super.unmarkText()
        isComposingText = false
    }

    /// 组字期间只重算「装饰画在哪里」，不碰字符属性、不改光标段落。
    ///
    /// `restyle` 在组字期间让路（I01–I04），按字符偏移自绘的装饰于是停在组字前的位置：
    /// 复选框会摆到别的行、勾选态跟着串行（issue #49），引用竖线与代码块底色会画到上一段。
    /// 这里只补区间，字体、字色、kern、「哪一段露源码」一律不动：组字期间画面不动，位置对。
    func refreshDecorationsDuringComposition() {
        let text = string
        let plan = EditorStylePlan.plan(for: text)
        setListMarkers(plan.scan.listMarkers, parsedFrom: text)
        codeBlockRanges = plan.spans.codeBlocks
        quoteMarks = plan.scan.quotes
    }

    /// 组合结束的兜底出口。`unmarkText` 与 `insertText` 都会走到，
    /// 个别输入法两者都不回调，只好在 `textDidChange` 里看 marked range 收尾。
    func endComposition() {
        isComposingText = false
    }

    /// 输入 `[` 自动补 `]`；再输入 `]` 时跳已补的那个。
    ///
    /// 只处理单字符输入，粘贴与输入法提交都走 `super`。
    /// 中文输入法组合期间（`hasMarkedText`）不介入，避免打乱候选。
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // 上屏＝组合结束。先落标记，好让 `textDidChange` 里的重排照常跑（I02）。
        isComposingText = false
        guard isEditable, !hasMarkedText(),
              let typed = string as? String, typed.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let selection = selectedRange()
        let ns = self.string as NSString

        if typed == "[" {
            // 有选区：包住选区，选区留在里面
            if selection.length > 0 {
                let inner = ns.substring(with: selection)
                let replacement = "[\(inner)]"
                guard shouldChangeText(in: selection, replacementString: replacement) else { return }
                textStorage?.replaceCharacters(in: selection, with: replacement)
                didChangeText()
                setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
                return
            }
            let insert = NSRange(location: selection.location, length: 0)
            guard shouldChangeText(in: insert, replacementString: "[]") else { return }
            textStorage?.replaceCharacters(in: insert, with: "[]")
            didChangeText()
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }

        // 空的一对 `[]` 退格：两个一起删，不留孤零零的 `]`
        if typed == "]", selection.length == 0,
           selection.location < ns.length,
           ns.character(at: selection.location) == 0x5D {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: 回车续行（issue #50）

    /// 回车时接着上一行的列表 / 待办 / 有序列表写下一项。
    ///
    /// 三条规则：
    /// - 待办：新条目一律未勾选（`- [x] ` 回车得到 `- [ ] `）。
    /// - 有序：序号 +1，`.` / `)` 与后随空格照搬，不重排全文（S38 的延续）。
    /// - 空条目回车：把前缀删掉、停在空行，等于退出列表。
    ///
    /// 代码块里不续（否则把代码行当成列表项）。缩进照搬，多级缩进因此能一直写下去。
    override func insertNewline(_ sender: Any?) {
        if continueListOnNewline() { return }
        super.insertNewline(sender)
    }

    /// 成功续行返回 true；返回 false 时交给 AppKit 的默认换行。
    private func continueListOnNewline() -> Bool {
        guard isEditable, !hasMarkedText() else { return false }
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }
        let caret = min(max(0, selection.location), ns.length)

        // 代码块内回车走原文：围栏里的 `- 甲` 不是列表（S33）。
        if codeBlockRanges.contains(where: { caret > $0.location && caret <= $0.location + $0.length }) {
            return false
        }

        let paragraph = ns.paragraphRange(for: NSRange(location: min(caret, ns.length - 1), length: 0))
        guard let marker = listMarkers.first(where: { $0.markerRange.location == paragraph.location }) else {
            return false
        }
        let prefixEnd = marker.markerRange.location + marker.markerRange.length
        guard caret >= prefixEnd else { return false }

        let paragraphEnd = paragraph.location + paragraph.length
        var contentEnd = paragraphEnd
        if contentEnd > paragraph.location, ns.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
        guard contentEnd >= prefixEnd else { return false }
        let content = ns.substring(with: NSRange(location: prefixEnd, length: contentEnd - prefixEnd))

        // 空条目：回车退出列表，前缀整段删掉。
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            let whole = NSRange(location: paragraph.location, length: contentEnd - paragraph.location)
            guard shouldChangeText(in: whole, replacementString: "") else { return false }
            textStorage?.replaceCharacters(in: whole, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: paragraph.location, length: 0))
            return true
        }

        let indentText = ns.substring(with: NSRange(location: paragraph.location, length: marker.indentChars))
        let original = ns.substring(with: marker.visibleRange)
        let next = ListLayout.nextMarkerText(for: marker, original: original)
        let replacement = "\n" + indentText + next
        let insert = NSRange(location: caret, length: 0)
        guard shouldChangeText(in: insert, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: insert, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: caret + (replacement as NSString).length, length: 0))
        return true
    }

    /// ⌘/ 切源码模式（Typora 同款快捷键）。
    var onToggleSourceMode: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains([.command, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "k",
           onConvertMention?() == true {
            return
        }
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers == "/" {
            onToggleSourceMode?()
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)), onEscape?() == true {
            return
        }
        super.doCommand(by: selector)
    }

    /// 光标所在的提及区间。光标在区间左闭右开范围内算命中。
    func mentionRangeAtCaret() -> NSRange? {
        let index = selectedRange().location
        return mentionRanges.first { index >= $0.location && index < $0.location + $0.length }
    }

    private func wikiTarget(at event: NSEvent) -> String? {
        wikiTarget(at: convert(event.locationInWindow, from: nil))
    }

    /// 视图坐标命中的引用目标。
    private func wikiTarget(at point: NSPoint) -> String? {
        let index = characterIndexForInsertion(at: point)
        guard index != NSNotFound else { return nil }
        for (range, target) in wikiHitRects {
            if index >= range.location && index < range.location + range.length {
                return target
            }
        }
        return nil
    }
}

/// 样式耗时的取证开关（issue #50）。
///
/// `SILVICS_STYLE_TRACE=1` 时每次 `restyle` 打一行到 stdout：字数、是否命中样式缓存、总耗时。
/// 长文切换的性能证据靠这条日志，不靠肉眼判断「卡不卡」。
enum StyleTrace {
    static let enabled = ProcessInfo.processInfo.environment["SILVICS_STYLE_TRACE"] == "1"
    nonisolated(unsafe) static var lastCached = false

    static func log(ms: Double, chars: Int) {
        print(String(format: "[style] chars=%d cache=%@ total=%.1f ms",
                     chars, lastCached ? "hit" : "miss", ms))
        // 重定向到文件时 stdout 是块缓冲，不冲就会被下一次 SIGTERM 吞掉（取证脚本踩过）。
        fflush(stdout)
    }
}

// MARK: - SwiftUI 桥

struct NoteEditorView: NSViewRepresentable {

    /// 正文初值。只在创建时读一次，之后由编辑器自己持有。
    let initialText: String
    /// 当前正文。外部改写（批量转换、改名、撤销）后要同步进来。
    let text: String
    /// 正文被外部改写的次数。只有它变了才把 `text` 同步进视图（issue #34）。
    var textRevision: Int = 0
    /// 取正文的实时读值。SwiftUI 传进来的 `text` 可能是上一轮渲染的快照，
    /// 真正要写进视图时以这个为准。不传则退回 `text`。
    var liveText: (() -> String)?
    /// 已解析的引用目标键集合。决定引用是实线还是虚线。
    let resolvedKeys: Set<String>
    /// 当前笔记的未链接提及。画点状下划线，`⌘⇧K` 转换。
    let mentions: [MentionDecoration]
    /// 外观设置。变化时重排样式（字号、行距、字体族）。
    let appearance: AppearanceSettings
    /// 只读：整篇按渲染态显示，不接 onChange、不弹补全、待办框不给点。
    var editable: Bool = true
    /// 是否把 `[[ ]]` 画成链接并可点。剪藏是单向引用，正文里的 `[[ ]]` 只是文本。
    var rendersWikiLinks: Bool = true
    /// 用户每改一个字就回报一次。
    var onChange: (String) -> Void
    /// 补全查询。
    var completionProvider: (String, Int) -> [CompletionItem]
    /// 采纳「新建《X》」时先建笔记，返回标题。
    var onCreateNote: (String) -> String?
    /// ⌘ 点击引用。
    var onOpenLink: (String) -> Void
    /// 补全是否展开。交给外部观察，用于状态栏提示。
    var onCompletionVisibilityChange: ((Bool) -> Void)?
    /// 紧凑排版：去掉正文四周的大留白、不要滚动条、纸面透明。AI 会话的气泡用它（issue #50）。
    var compact: Bool = false
    /// 高度跟着正文走。给 SwiftUI 的 `sizeThatFits` 用，气泡里不需要内层滚动（issue #50）。
    var autoHeight: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// 当前要写进视图的正文。`liveText` 优先，避免陈旧快照。
    var currentText: String { liveText?() ?? text }

    #if DEBUG
    /// 仅 DEBUG：这一段建过几个视图。取证脚本用它证明「敲字不再重建视图」。
    nonisolated(unsafe) static var makeCount = 0
    #endif

    func makeNSView(context: Context) -> NSScrollView {
        #if DEBUG
        Self.makeCount += 1
        #endif
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = !compact && !autoHeight
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = !compact
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder

        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        // 紧凑模式仍留出 `ListLayout.gutter` 的左边距：项目符号 / 复选框是挂在正文左缘左侧的，
        // 边距给 0 会被气泡裁掉（issue #50 踩过）。
        textView.textContainerInset = compact
            ? NSSize(width: ListLayout.gutter, height: 1)
            : NSSize(width: 28, height: 24)

        // 富文本：需要区间属性。但粘贴一律降级为纯文本。
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isEditable = editable
        textView.isSelectable = true
        // 撤销由 Coordinator 自管（issue #35）：系统的分组在真实事件循环里不闭合，
        // 整篇输入会合成一步。这里关掉它，避免两套栈互相打架。
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesRuler = false
        textView.drawsBackground = !compact
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.font = Theme.bodyFont
        textView.typingAttributes = Theme.typingAttributes()
        textView.string = currentText
        context.coordinator.wire(textView: textView)
        textView.onOpenWikiLink = { [weak coordinator = context.coordinator] title in
            coordinator?.handleOpenLink(title)
        }
        textView.onEscape = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.dismissCompletion()
        }
        textView.onConvertMention = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.convertMentionAtCaret()
        }

        scrollView.documentView = textView
        context.coordinator.attach(textView: textView, scrollView: scrollView)
        context.coordinator.restyle(force: true)

        // 只读视图（剪藏阅读、AI 气泡）不抢焦点：气泡一多，焦点会被最后一条消息抢走。
        if editable {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? EditorTextView else { return }

        // 外部改过正文（批量转换、改名、启用别名、撤销）才同步。
        //
        // 不能用「视图 != 传入值」判：SwiftUI 会把上一轮渲染算出的旧快照再跑一次 updateNSView，
        // 那时视图里已经是用户刚敲的字，按陈旧快照重设就把这段吞了（issue #34）。
        // 只认 `bodyRevision`：用户敲字不动它，外部改写才加一。
        if context.coordinator.syncExternalText(context.coordinator.parent.currentText, revision: textRevision) {
        } else if context.coordinator.lastResolvedKeys != resolvedKeys
                    || context.coordinator.lastMentions != mentions
                    || context.coordinator.lastAppearance != appearance {
            context.coordinator.restyle(force: true)
        }
    }

    /// 气泡高度：按给定宽度把正文排完，返回实际高度（issue #50）。
    ///
    /// 只在 `autoHeight` 时生效；编辑器本体不走这条路（它是滚动视图，自己撑满）。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard autoHeight, let textView = nsView.documentView as? NSTextView else { return nil }
        let width = proposal.width ?? nsView.bounds.width
        guard width > 1 else { return nil }
        context.coordinator.parent = self
        let height = context.coordinator.measuredHeight(of: textView, width: width)
        return CGSize(width: width, height: max(1, height))
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditorView
        private(set) weak var textView: EditorTextView?
        private weak var scrollView: NSScrollView?
        private let completion = CompletionPanelController()

        /// 这篇笔记专用的撤销栈（issue #35）。换笔记即随视图一起丢弃。
        private var undoStack = EditorUndoStack()

        private var isApplyingStyles = false
        /// 正在执行撤销/重做：此时正文变化不再记成新操作。
        private var isApplyingUndo = false
        /// 上一次改动后的正文。新操作的第一步拿它当 before。
        private var lastChangeLength = 0
        /// 自本次操作开始以来改动过的字符数（取绝对值）。
        private var charactersSinceBreak = 0
        /// 停笔后提交本次操作的定时器。
        private var idleCommitWork: DispatchWorkItem?
        /// 最后一次键入所在的段落。光标换段落时提交本次操作。
        private var lastEditParagraph: NSRange?
        /// 正在进行中的一次修改操作。
        private struct PendingEdit {
            var before: String
            var caretBefore: Int
            var name: String
        }
        private var pendingEdit: PendingEdit?
        /// 上一次改完的正文，用于下一次的 before。
        private var lastKnownText: String = ""
        /// 改动前记录的光标位置（`shouldChangeText` 里取）。
        private var caretBeforeChange: Int = 0
        /// 本次改动插入的文字（删除时为空）。步长判定用它。
        private var insertedTail: String = ""

        var canUndo: Bool { undoStack.canUndo || pendingEdit != nil }
        var canRedo: Bool { pendingEdit == nil && undoStack.canRedo }
        private var completionRange: NSRange?
        private var currentQuery: String = ""
        /// 上一次算出来的行内语法标记（带归属区间）。光标在段内进出时要它。
        private var lastInlineMarks: [InlineSyntaxMark] = []
        /// 上一次算出来的围栏行（整行）。渲染态整行折殁，光标进去才恢复。
        private var lastFenceLines: [NSRange] = []
        /// 上一次算出来的「带标记行的行首缩进」。光标移动不走它，但它必须一直压着（issue #41）。
        private var lastLineIndents: [NSRange] = []
        /// 上一次算出来的列表行（含缩进与标记区间），光标移动时重算压宽。
        private var lastListMarkers: [ListMarker] = []
        /// 上一次算出来的引用前缀与层级。
        private var lastQuoteMarks: [QuoteMark] = []
        /// 上一次算出来的表格块。光标换行时要在「露源码 / 渲染」之间切换。
        private var lastTableBlocks: [TableBlock] = []
        /// 上一次算出来的标题前缀区间（`#` 加其后空格）。光标换行时重算压宽。
        private var lastHeadingMarkers: [NSRange] = []
        /// 上一次的分桶依据，避免同段落内的每次光标移动都重设属性。
        private var lastCaretParagraph: NSRange?
        /// 行内标记按「光标是否落在这一处」切，同一段内挪光标也要重刷，所以要记选区。
        private var lastCaretKey: String = "none"

        /// 上一次回报给外部的正文，用于避免回环。
        fileprivate var lastPublishedText: String = ""
        fileprivate var lastResolvedKeys: Set<String> = []
        fileprivate var lastMentions: [MentionDecoration] = []
        fileprivate var lastAppearance = AppearanceSettings()

        /// 已经接受过的外部正文版本号。只增不减。
        private(set) var appliedRevision: Int = 0
        /// 组合态里拒不掉的正文，等组合结束再写。
        private var pendingExternal: (text: String, revision: Int)?
        private var pendingRetries = 0

        init(_ parent: NoteEditorView) {
            self.parent = parent
            self.lastPublishedText = parent.initialText
            self.lastResolvedKeys = parent.resolvedKeys
            self.lastMentions = parent.mentions
            self.lastAppearance = parent.appearance
            self.appliedRevision = parent.textRevision
        }

        /// 给定宽度把正文排完，量出需要的高度（`autoHeight` 用）。
        ///
        /// 用 TextKit 2 的 `enumerateTextSegments` 取所有行片段的底边，
        /// 而不是 `usedRect`（TextKit 2 下那个值不可靠）。
        func measuredHeight(of textView: NSTextView, width: CGFloat) -> CGFloat {
            guard let manager = textView.textLayoutManager,
                  let container = textView.textContainer,
                  let storage = textView.textStorage else { return 0 }
            let inset = textView.textContainerInset
            let padding = container.lineFragmentPadding
            let usable = max(1, width - inset.width * 2 - padding * 2)
            container.containerSize = NSSize(width: usable, height: .greatestFiniteMagnitude)
            container.widthTracksTextView = false
            manager.ensureLayout(for: manager.documentRange)
            guard storage.length > 0 else { return inset.height * 2 }
            var bottom: CGFloat = 0
            manager.enumerateTextSegments(in: manager.documentRange, type: .standard, options: []) { _, frame, _, _ in
                bottom = max(bottom, frame.maxY)
                return true
            }
            return bottom + inset.height * 2 + 1
        }

        /// 外部改了正文（DB 侧改写），同步记录避免被当成用户输入再存一次。
        func didReceiveExternalText(_ text: String) {
            lastPublishedText = text
        }

        /// 外部整体替换正文（改名、别名、批量转换、冲突合并）。
        ///
        /// 替换前必须清空撤销栈（issue #35）：旧栈里的键入动作带着旧正文的 range，
        /// 替换后接着 ⌘Z 会删到别的位置（实测旧代码抛 `NSRangeException`）。
        /// 清完以新正文作为新的起点，与「从磁盘重新载入文档」的语义一致。
        func applyExternalText(_ text: String, to textView: EditorTextView) {
            #if DEBUG
            DebugLog.write("[editor] 外部正文覆盖：旧=\(textView.string.count) 新=\(text.count)"
                + " 有撤销=\(undoStack.canUndo.description)")
            #endif
            resetUndoState(text: text)
            let caret = min(textView.selectedRange().location, (text as NSString).length)
            // `textView.string =` 会走一次 `textDidChange`，别把它记成一步（issue #35）。
            isApplyingUndo = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            isApplyingUndo = false
            didReceiveExternalText(text)
            restyle(force: true)
        }

        // MARK: 外部正文同步（issue #34）

        /// 只在「外部改写版本号」变化时把正文写进视图。
        ///
        /// 不能用「视图 != 传入值」判：SwiftUI 会把上一轮渲染算出的旧快照再跑一次
        /// `updateNSView`，那时视图里已是用户刚上屏的字，按旧快照重设就把它冲掉。
        ///
        /// 返回 true 表示这次拿到了外部正文（写了，或已在组合态里排队）。
        @discardableResult
        func syncExternalText(_ text: String, revision: Int) -> Bool {
            guard revision != appliedRevision else { return false }
            guard let textView else { return false }

            // 组合态：先记下，等输入法上屏后再写。组合期重设正文会清掉 marked range，
            // 候选窗被顶掉，正在敲的拼音和后续上屏一起丢。
            if textView.hasMarkedText() {
                pendingExternal = (text, revision)
                pendingRetries = 0
                schedulePendingExternal()
                return true
            }

            appliedRevision = revision
            pendingExternal = nil
            // 内容一样就别动：`applyExternalText` 会清撤销栈，白白丢掉 ⌘Z（issue #35）。
            guard textView.string != text else {
                didReceiveExternalText(text)
                return true
            }
            applyExternalText(text, to: textView)
            return true
        }

        /// 组合结束后把排队的外部正文落下。
        ///
        /// 只在用户没有继续敲字时落：组合上屏会先过一次 `textDidChange`，
        /// 那里发现正文已经变了，就把这次外部写入作废（用户输入优先）。
        private func commitPendingExternal(_ pending: (text: String, revision: Int)) {
            guard let textView else { return }
            appliedRevision = pending.revision
            pendingExternal = nil
            guard textView.string != pending.text else {
                didReceiveExternalText(pending.text)
                return
            }
            applyExternalText(pending.text, to: textView)
        }

        /// 20 ms 一轮，最多试 5 秒；组合一直不结束就丢掉，宁可不刷新也不打断输入。
        private func schedulePendingExternal() {
            guard pendingExternal != nil else { return }
            guard pendingRetries < 250 else {
                pendingExternal = nil
                return
            }
            pendingRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self, let pending = self.pendingExternal else { return }
                guard let textView = self.textView else { return }
                if textView.hasMarkedText() {
                    self.schedulePendingExternal()
                    return
                }
                self.commitPendingExternal(pending)
            }
        }

        /// 视图被销毁（切换笔记、窗口关闭）时收掉浮层，断开代理。
        func teardown() {
            completion.hide()
            idleCommitWork?.cancel()
            idleCommitWork = nil
            pendingEdit = nil
            undoStack.removeAll()
            textView?.onUndo = nil
            textView?.onRedo = nil
            textView?.onWillChange = nil
            textView?.delegate = nil
            textView = nil
            scrollView = nil
        }

        /// 接线：代理与撤销/重做四个回调。测试也走这里，避免测试另写一份。
        func wire(textView: EditorTextView) {
            textView.delegate = self
            textView.onWillChange = { [weak self] caret, inserted in
                self?.willChangeText(caret: caret, inserted: inserted)
            }
            textView.onUndo = { [weak self] in self?.performUndo() ?? false }
            textView.onRedo = { [weak self] in self?.performRedo() ?? false }
            textView.canUndoAction = { [weak self] in self?.canUndo ?? false }
            textView.canRedoAction = { [weak self] in self?.canRedo ?? false }
            textView.onToggleSourceMode = { [weak self, weak textView] in
                guard let textView else { return }
                textView.showsSource.toggle()
                self?.restyle(force: true)
            }
        }

        func attach(textView: EditorTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            resetUndoState(text: textView.string, clearStack: false)
        }

        // MARK: 撤销（issue #35）

        /// 重置撤销状态。外部整体替换正文时连栈一起清。
        private func resetUndoState(text: String, clearStack: Bool = true) {
            if clearStack { undoStack.removeAll() }
            pendingEdit = nil
            lastKnownText = text
            lastChangeLength = (text as NSString).length
            charactersSinceBreak = 0
            lastEditParagraph = nil
            idleCommitWork?.cancel()
            idleCommitWork = nil
        }

        /// `shouldChangeText` 回调：记下改动前光标与这次插入的文字。
        func willChangeText(caret: NSRange, inserted: String?) {
            guard !isApplyingUndo, parent.editable else { return }
            caretBeforeChange = caret.location
            insertedTail = String((inserted ?? "").suffix(4))
            if pendingEdit == nil {
                pendingEdit = PendingEdit(
                    before: lastKnownText,
                    caretBefore: caret.location,
                    name: "打字"
                )
            }
        }

        /// 一次正文改动之后：更新本次操作、按规则决定是否收尾。由 `textDidChange` 调。
        private func noteEdit(text: String) {
            guard !isApplyingUndo, parent.editable else { return }
            if pendingEdit == nil {
                pendingEdit = PendingEdit(
                    before: lastKnownText,
                    caretBefore: caretBeforeChange,
                    name: "打字"
                )
            }
            let newLength = (text as NSString).length
            charactersSinceBreak += abs(newLength - lastChangeLength)
            lastChangeLength = newLength
            lastKnownText = text
            if UndoPolicy.shouldBreak(tail: insertedTail, charactersSinceBreak: charactersSinceBreak) {
                commitPendingEdit()
            } else {
                scheduleIdleCommit()
            }
            if let textView {
                lastEditParagraph = paragraphRange(at: textView.selectedRange().location)
            }
        }

        /// 给正在进行的操作换个名字（勾选待办、转换提及……），并立刻收尾。
        private func commitPendingEdit(named name: String? = nil) {
            if let name { pendingEdit?.name = name }
            commitPendingEdit()
        }

        /// 把进行中的一次操作压进撤销栈。
        func commitPendingEdit() {
            idleCommitWork?.cancel()
            idleCommitWork = nil
            charactersSinceBreak = 0
            guard let pending = pendingEdit, let textView else { return }
            pendingEdit = nil
            let after = textView.string
            undoStack.record(EditorUndoStep(
                before: pending.before,
                after: after,
                caretBefore: pending.caretBefore,
                caretAfter: textView.selectedRange().location,
                name: pending.name
            ))
            lastKnownText = after
            lastChangeLength = (after as NSString).length
        }

        /// 停笔一会儿也算一步：长句中间没有标点时，不该把整段合成一步。
        private func scheduleIdleCommit() {
            idleCommitWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.commitPendingEdit()
            }
            idleCommitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + UndoPolicy.idleInterval, execute: work)
        }

        /// `⌘Z`。先收掉正在打的这一段，再退一步。
        func performUndo() -> Bool {
            commitPendingEdit()
            guard let textView, let step = undoStack.takeUndo() else { return false }
            apply(text: step.before, caret: step.caretBefore, to: textView)
            return true
        }

        /// `⌘⇧Z`。
        func performRedo() -> Bool {
            commitPendingEdit()
            guard let textView, let step = undoStack.takeRedo() else { return false }
            apply(text: step.after, caret: step.caretAfter, to: textView)
            return true
        }

        /// 把一步撤销/重做写回编辑器。
        ///
        /// 整体替换正文，不走 `NSTextView` 的撤销栈：快照不会失效，
        /// 外部改过正文也不会删错位置。
        private func apply(text: String, caret: Int, to textView: EditorTextView) {
            isApplyingUndo = true
            let location = min(max(0, caret), (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(NSRange(location: location, length: 0))
            isApplyingUndo = false
            lastKnownText = text
            lastChangeLength = (text as NSString).length
            charactersSinceBreak = 0
            pendingEdit = nil
            lastEditParagraph = paragraphRange(at: location)
            didReceiveExternalText(text)
            restyle(force: true)
            parent.onChange(text)
        }

        /// `⌘⇧K`：把光标所在提及转成 `[[引用]]`。走 `shouldChangeText`，可撤销。
        func convertMentionAtCaret() -> Bool {
            guard let textView,
                  let range = textView.mentionRangeAtCaret(),
                  let decoration = parent.mentions.first(where: { $0.range == range }) else {
                return false
            }
            let replacement = "[[\(decoration.title)]]"
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
            textView.textStorage?.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(
                location: range.location + (replacement as NSString).length,
                length: 0
            ))
            // 一次转换 = 一步撤销（issue #35）。
            commitPendingEdit(named: "转换提及")
            return true
        }

        func handleOpenLink(_ title: String) {
            parent.onOpenLink(title)
        }

        func dismissCompletion() -> Bool {
            guard completion.isVisible else { return false }
            completion.hide()
            parent.onCompletionVisibilityChange?(false)
            return true
        }

        // MARK: 样式

        /// 重排全篇属性。
        ///
        /// 语法标记按光标段落分两组：光标所在段落用可读色，其余段落 `.clear`
        /// （字符宽度不变，文本一个不动）。光标移动不走这里，走 `refreshSyntaxMarksForCaret`。
        func restyle(force: Bool) {
            let traceStart = StyleTrace.enabled ? CFAbsoluteTimeGetCurrent() : 0
            defer {
                if StyleTrace.enabled, let storage = textView?.textStorage {
                    StyleTrace.log(
                        ms: (CFAbsoluteTimeGetCurrent() - traceStart) * 1000,
                        chars: storage.length
                    )
                }
            }
            guard let textView, let storage = textView.textStorage else { return }
            guard !isApplyingStyles else { return }
            // 中文输入法组合期间不改属性、不重设 typingAttributes（I01–I04）。
            guard !textView.hasMarkedText(), !textView.isComposingText else { return }
            isApplyingStyles = true
            defer { isApplyingStyles = false }

            let text = storage.string
            lastPublishedText = text
            lastResolvedKeys = parent.resolvedKeys
            lastMentions = parent.mentions
            lastAppearance = parent.appearance

            // 解析 + 逐行扫描 + 表格识别收在一次，并按正文缓存（issue #50）：
            // 长文切换、只读 ↔ 编辑来回切时不再重算整篇。
            let plan = EditorStylePlan.plan(for: text)
            let scan = plan.scan
            let spans = plan.spans
            let wikis = parent.rendersWikiLinks ? WikiScanner.scan(text) : []
            let listMarkers = scan.listMarkers
            let lineIndents = scan.indents
            let quoteMarks = scan.quotes
            let tableBlocks = plan.tables
            let fullRange = NSRange(location: 0, length: storage.length)
            let caretParagraph = parent.editable ? paragraphRange(at: textView.selectedRange().location) : nil
            let caret = parent.editable ? textView.selectedRange() : nil
            // 行内标记：渲染态压宽，光标落进那一段才露出（对齐 Typora）。
            let inlineMarks = MarkdownStyler.inlineSyntaxMarks(in: text, spans: spans, links: wikis)
            // 源码模式（⌘/）：所有标记恢复原宽，装饰一律不画。
            let expanded = textView.showsSource

            let selection = textView.selectedRanges
            storage.beginEditing()

            storage.setAttributes(Theme.baseAttributes(), range: fullRange)

            applyHeadings(spans, storage, fullRange)
            // 标题前缀与列表标记同一套：隐藏态压到 0 宽（issue #8）。
            applyHeadingMarkers(
                spans.headingMarkers, caretParagraph: caretParagraph, expanded: expanded, storage: storage
            )
            // 表格先写等宽 + kern，`applyInline` 的加粗 / 斜体再叠在它上面。
            applyTables(tableBlocks, in: text, caretParagraph: caretParagraph, expanded: expanded, storage: storage)
            applyInline(spans, storage, fullRange)
            applyBlocks(spans, in: text, fenceLines: plan.fenceLines, storage, fullRange)
            applyFenceLines(plan.fenceLines, caretParagraph: caretParagraph, expanded: expanded, storage: storage)
            applyLists(
                listMarkers, quotes: quoteMarks, caretParagraph: caretParagraph, expanded: expanded, storage: storage
            )
            applyWikiLinks(wikis, in: text, storage, fullRange)
            applyMentions(storage)
            applyInlineMarks(inlineMarks, caret: caret, expanded: expanded, storage: storage)
            // 放在最后：`applyLists` 在光标段落会把整段前缀恢复原宽，缩进要再压回去。
            applyLineIndents(lineIndents, storage: storage)

            storage.endEditing()

            lastInlineMarks = inlineMarks
            lastFenceLines = plan.fenceLines
            lastListMarkers = listMarkers
            lastLineIndents = lineIndents
            lastQuoteMarks = quoteMarks
            lastTableBlocks = tableBlocks
            lastHeadingMarkers = spans.headingMarkers
            lastCaretParagraph = caretParagraph
            lastCaretKey = caret.map { "\($0.location)-\($0.length)" } ?? "none"
            // 块底色由视图自绘，区间变了要重画。
            textView.codeBlockRanges = spans.codeBlocks
            textView.setListMarkers(listMarkers, parsedFrom: text)
            textView.quoteMarks = quoteMarks
            textView.tableBlocks = tableBlocks
            textView.caretParagraph = caretParagraph

            textView.typingAttributes = Theme.typingAttributes()
            textView.selectedRanges = selection

            StyleTrace.lastCached = plan.fromCache
            // 记录引用命中区间，供 ⌘ 点击使用
            textView.wikiHitRects = parent.rendersWikiLinks ? wikis.map { link in
                (link.nsRange(in: text), link.target)
            } : []
            textView.mentionRanges = parent.mentions.map(\.range)
        }

        /// 未链接提及：淡色点状下划线（设计文档 5.4）。
        private func applyMentions(_ storage: NSTextStorage) {
            for decoration in parent.mentions {
                guard let r = clamp(decoration.range, storage.length) else { continue }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: Theme.mentionUnderline,
                ], range: r)
            }
        }

        /// 行内语法标记：渲染态压到 ≈ 0 宽，光标落进它那一段才恢复原宽、染色。
        ///
        /// 为何要压宽（对齐 Typora）：只把字符染色成透明的话，`**加粗**` 里那两个星号
        /// 仍然占 14 pt，渲染态正文里到处是空洞（issue #50 审计 01）。
        private func applyInlineMarks(
            _ marks: [InlineSyntaxMark],
            caret: NSRange?,
            expanded: Bool,
            storage: NSTextStorage
        ) {
            guard !marks.isEmpty else { return }
            let split = expanded
                ? (show: marks.map(\.range), hide: [NSRange]())
                : MarkdownStyler.splitInline(marks, caret: caret)
            let ns = storage.string as NSString
            for range in split.hide {
                guard let r = clamp(range, storage.length) else { continue }
                let marker = ns.substring(with: r)
                storage.addAttributes(Theme.compressedMarkerAttributes(for: marker), range: r)
            }
            for range in split.show {
                guard let r = clamp(range, storage.length) else { continue }
                // 只撤 kern、换字色：字重 / 等宽字号留给所属 span，露出来的就是原文。
                storage.removeAttribute(.kern, range: r)
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarkActive, range: r)
            }
        }

        /// 围栏行（` ```swift ` / ` ``` `）：渲染态整行折殁，光标进入才恢复。
        ///
        /// 不折的话围栏行里的语言名（`swift`）会孤零零留在块顶，而且那块白高出一整行。
        private func applyFenceLines(
            _ lines: [NSRange],
            caretParagraph: NSRange?,
            expanded: Bool,
            storage: NSTextStorage
        ) {
            guard !lines.isEmpty else { return }
            let ns = storage.string as NSString
            for range in lines {
                guard let r = clamp(range, storage.length) else { continue }
                if expanded || (caretParagraph.map { overlaps(range, $0) } ?? false) {
                    storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: r)
                } else {
                    let line = ns.substring(with: r)
                    storage.addAttributes(Theme.collapsedLineAttributes(for: line), range: r)
                }
            }
        }

        private func overlaps(_ range: NSRange, _ other: NSRange) -> Bool {
            guard other.length > 0, range.length > 0 else { return false }
            return range.location < other.location + other.length
                && other.location < range.location + range.length
        }

        /// 语法标记可见性（旧通道）：只改字色。已由 `applyInlineMarks` 接管行内标记。
        private func applySyntaxMarks(_ marks: SyntaxMarkVisibility, _ storage: NSTextStorage) {
            for range in marks.hide {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarkHidden, range: r)
            }
            for range in marks.show {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarkActive, range: r)
            }
        }

        /// 光标换了段落才重刷标记可见性。不重解析 Markdown，不碰选区，不碰 typingAttributes。
        private func refreshSyntaxMarksForCaret() {
            guard let textView, let storage = textView.textStorage else { return }
            guard !isApplyingStyles, !textView.hasMarkedText(), !textView.isComposingText else { return }
            guard !lastInlineMarks.isEmpty || !lastListMarkers.isEmpty || !lastQuoteMarks.isEmpty
                    || !lastTableBlocks.isEmpty || !lastHeadingMarkers.isEmpty
                    || !lastLineIndents.isEmpty || !lastFenceLines.isEmpty else {
                return
            }
            let caret = parent.editable ? textView.selectedRange() : nil
            let caretParagraph = parent.editable ? paragraphRange(at: textView.selectedRange().location) : nil
            // 行内标记按「光标是否在这一段里」切，光标在同一段内逐个字符挪也要跟着变。
            let caretKey = caret.map { "\($0.location)-\($0.length)" } ?? "none"
            guard caretParagraph != lastCaretParagraph || caretKey != lastCaretKey else { return }

            storage.beginEditing()
            let expanded = textView.showsSource
            applyInlineMarks(lastInlineMarks, caret: caret, expanded: expanded, storage: storage)
            // 围栏行 / 表格分隔行：渲染态折殁，光标进去才恢复（其余块级标记已不再随光标变化）。
            applyFenceLines(lastFenceLines, caretParagraph: caretParagraph, expanded: expanded, storage: storage)
            applyTables(
                lastTableBlocks, in: storage.string, caretParagraph: caretParagraph,
                expanded: expanded, storage: storage
            )
            storage.endEditing()
            lastCaretParagraph = caretParagraph
            lastCaretKey = caretKey
            textView.caretParagraph = caretParagraph
        }

        /// 列表行：段落缩进按层级算，行首标记**永远**压到 ≈ 0 宽。
        ///
        /// 第 1 级与标题、正文同左缘（issue #50）；每深一级右移 `ListLayout.levelStep`。
        /// 为什么不再随光标露出（对齐 Typora）：一露就是 10–28 pt 的横向位移，
        /// 写列表时每行都在跳（审计 03 / 04）。改标记靠快捷键与源码模式。
        private func applyLists(
            _ markers: [ListMarker],
            quotes: [QuoteMark],
            caretParagraph: NSRange?,
            expanded: Bool,
            storage: NSTextStorage
        ) {
            let ns = storage.string as NSString
            for marker in markers {
                // 段落样式覆盖整段：软换行后的行也要落在同一缩进。
                guard ns.length > 0 else { continue }
                let paragraph = ns.paragraphRange(for: NSRange(
                    location: min(max(0, marker.markerRange.location), ns.length - 1),
                    length: 0
                ))
                guard let whole = clamp(paragraph, storage.length) else { continue }
                storage.addAttribute(
                    .paragraphStyle,
                    value: Theme.listParagraph(level: marker.level),
                    range: whole
                )

                setMarkerWidth(marker.markerRange, compressed: !expanded, storage: storage)
            }
            // 引用：**每一行**的前缀都压宽。只压第一行会让第 2 行起右移一个 `> ` 的宽度（审计 05）。
            for mark in quotes {
                for range in mark.allPrefixes {
                    setMarkerWidth(range, compressed: !expanded, storage: storage)
                }
                // 引用行的段落缩进按它自己的层级：`  > 甲` 比 `> 甲` 深一级。
                guard ns.length > 0 else { continue }
                let paragraph = ns.paragraphRange(for: NSRange(
                    location: min(max(0, mark.range.location), ns.length - 1),
                    length: 0
                ))
                guard let whole = clamp(paragraph, storage.length) else { continue }
                storage.addAttribute(
                    .paragraphStyle,
                    value: Theme.quoteParagraph(level: mark.level),
                    range: whole
                )
            }
        }

        /// 表格：整块等宽 13pt，按显示宽度给每格末字符补 kern，pipe 与分隔行淡化。
        ///
        /// 光标所在行不补 kern，pipe 回到等宽字体的自然位置 —— 那一行就是源码。
        /// 属性全部由 `TableLayout.attributes` 算（纯函数，有单测），这里只负责写进存储。
        private func applyTables(
            _ blocks: [TableBlock],
            in text: String,
            caretParagraph: NSRange?,
            expanded: Bool,
            storage: NSTextStorage
        ) {
            guard !blocks.isEmpty else { return }
            for block in blocks {
                for item in TableLayout.attributes(
                    for: block, in: text, caretParagraph: caretParagraph, expanded: expanded
                ) {
                    guard let r = clamp(item.range, storage.length) else { continue }
                    storage.addAttributes(item.attributes, range: r)
                }
            }
        }

        /// 行首缩进：**永远**不占宽，光标在不在这一段都一样（issue #41）。
        ///
        /// 原来光标段落会把整段前缀（含缩进）恢复原宽，`  - 甲` 一进编辑态正文就右移 8 pt。
        /// 缩进对流式排版没有意义，藏起来；光标段落只露语法标记本身。
        private func applyLineIndents(_ ranges: [NSRange], storage: NSTextStorage) {
            guard !ranges.isEmpty else { return }
            let ns = storage.string as NSString
            for range in ranges {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttributes(ListLayout.indentAttributes(for: ns.substring(with: r)), range: r)
            }
        }

        private func setMarkerWidth(_ range: NSRange, compressed: Bool, storage: NSTextStorage) {
            guard let r = clamp(range, storage.length) else { return }
            let marker = (storage.string as NSString).substring(with: r)
            if compressed {
                storage.addAttributes(Theme.compressedMarkerAttributes(for: marker), range: r)
            } else {
                storage.removeAttribute(.kern, range: r)
                storage.addAttributes(Theme.visibleMarkerAttributes(), range: r)
            }
        }

        /// 光标位置所在段落的区间（含行尾换行，与 `NSString.paragraphRange(for:)` 一致）。
        private func paragraphRange(at location: Int) -> NSRange? {
            guard let textView else { return nil }
            let ns = textView.string as NSString
            guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
            let clamped = min(max(0, location), ns.length)
            return ns.paragraphRange(for: NSRange(location: clamped, length: 0))
        }

        private func applyHeadings(_ spans: EditorSpans, _ storage: NSTextStorage, _ full: NSRange) {
            for (level, range) in spans.headings {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttributes([
                    .font: Theme.headingFont(level: level),
                    .paragraphStyle: Theme.headingParagraph(level: level),
                ], range: r)
            }
            // 前缀宽度与颜色由 `applyHeadingMarkers` 与 `applySyntaxMarks` 按光标段落处理。
        }

        /// 标题前缀（`#` 加其后空格）：隐藏态压到 0 宽，光标段落恢复原标题字号。
        ///
        /// 只改属性不改字符。压宽之前正文被 `#` 顶出一个缩进（issue #8）。
        /// 属性构造在 `HeadingLayout`（纯函数，有单测）。
        private func applyHeadingMarkers(
            _ ranges: [NSRange],
            caretParagraph: NSRange?,
            expanded: Bool,
            storage: NSTextStorage
        ) {
            guard !ranges.isEmpty else { return }
            let ns = storage.string as NSString
            guard ns.length > 0 else { return }
            for range in ranges {
                guard let r = clamp(range, storage.length) else { continue }
                let marker = ns.substring(with: r)
                storage.removeAttribute(.kern, range: r)
                let attributes = expanded
                    ? HeadingLayout.visibleAttributes(forMarker: marker)
                    : HeadingLayout.attributes(forMarker: marker, range: r, caretParagraph: caretParagraph)
                storage.addAttributes(attributes, range: r)
            }
        }

        private func applyInline(_ spans: EditorSpans, _ storage: NSTextStorage, _ full: NSRange) {
            // 粗体：保留现有字号，只加粗
            for range in spans.strongs {
                guard let r = clamp(range, storage.length) else { continue }
                storage.enumerateAttribute(.font, in: r) { value, subRange, _ in
                    guard let font = value as? NSFont else { return }
                    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    storage.addAttribute(.font, value: bold, range: subRange)
                }
            }
            // 斜体：同样保留字号
            for range in spans.emphases {
                guard let r = clamp(range, storage.length) else { continue }
                storage.enumerateAttribute(.font, in: r) { value, subRange, _ in
                    guard let font = value as? NSFont else { return }
                    let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    storage.addAttribute(.font, value: italic, range: subRange)
                }
            }
            // 行内代码
            for range in spans.inlineCodes {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttributes([
                    .font: Theme.codeFont,
                    .backgroundColor: Theme.codeBackground,
                    .foregroundColor: Theme.secondaryText,
                ], range: r)
            }
            // 普通 Markdown 链接：`[...](url)` 的定界符已被压宽，只剩链接文字，
            // 所以这里要给「像链接」的色，而不是次级灰（否则渲染态看着像删除线文本）。
            for range in spans.markdownLinks {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttribute(.foregroundColor, value: Theme.linkText, range: r)
            }
        }

        private func applyBlocks(
            _ spans: EditorSpans,
            in text: String,
            fenceLines: [NSRange],
            _ storage: NSTextStorage,
            _ full: NSRange
        ) {
            for range in spans.codeBlocks {
                guard let r = clamp(range, storage.length) else { continue }
                // 只给字体与段落样式；底色交给 `EditorTextView.drawBackground(in:)`
                // （`.backgroundColor` 在 TextKit 2 下只按字形游程上色，会写成一条条短灰块）。
                storage.addAttributes([
                    .font: Theme.codeFont,
                    .paragraphStyle: Theme.codeParagraph(),
                ], range: r)
                // 块内换行不是新段落：行与行之间不该吃 `paragraphSpacing`。
                // 不压的话 10pt 段后距会把每行推开，13pt 的代码排成 36pt 行距（审计 07）。
                applyCodeLineSpacing(in: r, storage: storage)
            }
            // 围栏行只淡化：整行次级色，不加底色、不改字重。
            for range in fenceLines {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: r)
            }
            applyCodeTokens(spans, in: text, storage)
            for range in spans.blockQuotes {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttributes([
                    .foregroundColor: Theme.secondaryText,
                    .paragraphStyle: Theme.quoteParagraph(),
                ], range: r)
            }
        }

        /// 代码块内逐行压掉段间距：首行留 `paragraphSpacingBefore`，末行留 `paragraphSpacing`，
        /// 中间行两头都归零。行距只由 `lineSpacing` 决定。
        private func applyCodeLineSpacing(in block: NSRange, storage: NSTextStorage) {
            let ns = storage.string as NSString
            guard block.length > 0, block.location + block.length <= ns.length else { return }
            var lines: [NSRange] = []
            var index = block.location
            let end = block.location + block.length
            while index < end {
                let line = ns.lineRange(for: NSRange(location: index, length: 0))
                guard line.length > 0 else { break }
                lines.append(line)
                index = line.location + line.length
            }
            guard lines.count > 2 else { return }
            for (offset, line) in lines.enumerated() {
                guard let r = clamp(line, storage.length) else { continue }
                let style = Theme.codeParagraph().mutableCopy() as! NSMutableParagraphStyle
                if offset > 0 { style.paragraphSpacingBefore = 0 }
                if offset < lines.count - 1 { style.paragraphSpacing = 0 }
                storage.addAttribute(.paragraphStyle, value: style, range: r)
            }
        }

        /// 代码块上色。围栏行不碰，只给内容行按 `CodeLexer` 的 token 改字色。
        /// `plain` 不上色，保留正文色。
        private func applyCodeTokens(_ spans: EditorSpans, in text: String, _ storage: NSTextStorage) {
            let ns = text as NSString
            for region in MarkdownStyler.codeBlockRegions(in: text, spans: spans) {
                guard region.contentRange.location >= 0,
                      region.contentRange.location + region.contentRange.length <= ns.length else { continue }
                let code = ns.substring(with: region.contentRange)
                let base = region.contentRange.location
                for token in CodeLexer.lex(code, language: region.language) {
                    guard let color = Theme.tokenColor(token.kind) else { continue }
                    let range = NSRange(location: base + token.range.location, length: token.range.length)
                    guard let r = clamp(range, storage.length) else { continue }
                    storage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
        }

        /// 引用样式：方括号淡化，标题着色加下划线。悬空用虚线。
        private func applyWikiLinks(
            _ links: [WikiLink],
            in text: String,
            _ storage: NSTextStorage,
            _ full: NSRange
        ) {
            for link in links {
                let whole = link.nsRange(in: text)
                guard let r = clamp(whole, storage.length), r.length >= 4 else { continue }
                let inner = NSRange(location: r.location + 2, length: r.length - 4)

                let resolved = parent.resolvedKeys.contains(TextNormalizer.key(link.target))
                let color = resolved ? Theme.linkText : Theme.danglingText
                let underline: NSUnderlineStyle = resolved ? .single : [.single, .patternDash]

                // 整段先给链接色
                storage.addAttributes([
                    .foregroundColor: color,
                    .underlineStyle: underline.rawValue,
                    .underlineColor: color,
                ], range: r)

                // 内部文字稍重，方括号退到语法色
                storage.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: inner
                )
                // 方括号的颜色交给 `applySyntaxMarks` 统一处理（按光标段落显示或隐藏）
                storage.addAttributes([
                    .underlineStyle: 0,
                ], range: NSRange(location: r.location, length: 2))
                storage.addAttributes([
                    .underlineStyle: 0,
                ], range: NSRange(location: r.location + r.length - 2, length: 2))

                // 显示名与锚点淡化
                if link.display != nil || link.anchor != nil {
                    storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: inner)
                }
            }
        }

        private func clamp(_ range: NSRange, _ length: Int) -> NSRange? {
            guard range.location >= 0, range.location <= length else { return nil }
            let maxLen = length - range.location
            guard maxLen > 0 else { return nil }
            return NSRange(location: range.location, length: min(range.length, maxLen))
        }

        // MARK: 文本变化

        func textDidChange(_ notification: Notification) {
            guard parent.editable else { return }
            guard let textView = notification.object as? EditorTextView else { return }
            let text = textView.string
            // 兜底：marked range 已经没了就说明组合结束（个别输入法不回调 unmarkText）。
            if textView.isComposingText, !textView.hasMarkedText() { textView.endComposition() }
            // 用户在排队的外部正文落下之前就自己敲了字：以视图为准，丢掉那次外部写入。
            if let pending = pendingExternal, text != pending.text {
                pendingExternal = nil
                appliedRevision = pending.revision
            }
            if textView.isComposingText {
                // 组字中属性不动，但浮层位置要跟得上正文：只补标记，不重排样式（issue #49）。
                textView.refreshDecorationsDuringComposition()
            }
            restyle(force: false)
            parent.onChange(text)
            refreshCompletionIfNeeded()
            // 输入法组合期间不记：组合完成后一次记成一步，撤销才不会退到半截拼音。
            if !textView.hasMarkedText() {
                noteEdit(text: text)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // 光标移动要重算「哪一段露源码」，但不能重排全篇（否则滚动会跳）。
            refreshSyntaxMarksForCaret()
            // 光标移动时刷新补全的候选（在同一条引用内左右移动）
            if completion.isVisible {
                refreshCompletionIfNeeded()
            }
            // 光标跳到别的段落：一次撤销不该跨段落（issue #35）。
            guard parent.editable, !isApplyingStyles, !isApplyingUndo, let textView else { return }
            let caret = paragraphRange(at: textView.selectedRange().location)
            if let last = lastEditParagraph, caret?.location != last.location {
                commitPendingEdit()
                lastEditParagraph = caret
            }
        }

        // MARK: 补全

        /// 光标前若是一段未闭合的 `[[`，返回它的起点与查询串。
        private func activeWikiContext() -> (range: NSRange, query: String)? {
            guard let textView else { return nil }
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location > 0 else { return nil }
            let ns = textView.string as NSString
            let lookback = min(selection.location, 80)
            let start = selection.location - lookback
            let window = ns.substring(with: NSRange(location: start, length: lookback))
            guard let found = window.range(of: "[[", options: .backwards) else { return nil }

            let offsetInWindow = window.distance(from: window.startIndex, to: found.lowerBound)
            let afterOpen = String(window[found.upperBound...])
            if afterOpen.contains("]]") || afterOpen.contains("\n") { return nil }

            let absoluteOpen = start + offsetInWindow
            let queryLength = selection.location - absoluteOpen - 2
            guard queryLength >= 0 else { return nil }
            let query = ns.substring(with: NSRange(location: absoluteOpen + 2, length: queryLength))
            return (NSRange(location: absoluteOpen, length: selection.location - absoluteOpen), query)
        }

        private func refreshCompletionIfNeeded() {
            guard parent.editable else { return }
            guard let textView else { DebugLog.write("refresh: no textView"); return }
            guard let context = activeWikiContext() else {
                DebugLog.write("refresh: no active context, caret=\(textView.selectedRange())")
                if completion.isVisible {
                    completion.hide()
                    parent.onCompletionVisibilityChange?(false)
                }
                completionRange = nil
                return
            }

            completionRange = context.range
            currentQuery = context.query
            let items = parent.completionProvider(context.query, 8)
            DebugLog.write("refresh: query=\(context.query) items=\(items.count) range=\(context.range)")
            guard !items.isEmpty else {
                completion.hide()
                parent.onCompletionVisibilityChange?(false)
                return
            }
            let anchor = caretAnchorRect(in: textView)
            completion.show(items: items, anchor: anchor, in: textView) { [weak self] item in
                self?.commit(item)
            }
            if !completion.isVisible {
                parent.onCompletionVisibilityChange?(true)
            }
        }

        private func caretAnchorRect(in textView: NSTextView) -> NSRect {
            let selection = textView.selectedRange()
            let glyphRange = textView.layoutManager?.glyphRange(
                forCharacterRange: NSRange(location: max(0, selection.location), length: 0),
                actualCharacterRange: nil
            ) ?? NSRange(location: 0, length: 0)
            var rect = textView.layoutManager?.boundingRect(
                forGlyphRange: glyphRange, in: textView.textContainer!
            ) ?? .zero
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            if rect.height <= 0 { rect.size.height = 18 }
            return rect
        }

        private func commit(_ item: CompletionItem) {
            guard let textView, let range = completionRange else { return }
            completion.hide()
            parent.onCompletionVisibilityChange?(false)

            var title = item.title
            if item.isCreate {
                guard let created = parent.onCreateNote(title) else { return }
                title = created
            }

            let replacement = "[[\(title)]]"
            // 自动补的 `]]` 还在光标后面时一起替换掉，否则写成 `[[标题]]]]`。
            let full = WikiScanner.commitReplacementRange(range, in: textView.string)
            if textView.shouldChangeText(in: full, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: full, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: full.location + (replacement as NSString).length, length: 0))
                // 一次补全 = 一步撤销（issue #35）。
                commitPendingEdit(named: "插入引用")
            }
            completionRange = nil
        }

        // MARK: 按键拦截

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard completion.isVisible else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                completion.move(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                completion.move(1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                if let item = completion.selectedItem { commit(item) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                completion.hide()
                parent.onCompletionVisibilityChange?(false)
                return true
            default:
                return false
            }
        }
    }
}
