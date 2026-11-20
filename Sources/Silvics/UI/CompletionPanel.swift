import AppKit
import SwiftUI

/// 补全浮层的数据源。用 ObservableObject 驱动 SwiftUI 列表。
final class CompletionModel: ObservableObject {
    @Published var items: [CompletionItem] = []
    @Published var selected: Int = 0

    var current: CompletionItem? {
        guard items.indices.contains(selected) else { return nil }
        return items[selected]
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }
}

/// 无标题浮动面板，贴在光标下方。
final class CompletionPanelController {

    private let panel: NSPanel
    private let model = CompletionModel()
    private var onCommit: ((CompletionItem) -> Void)?

    private static let rowHeight: CGFloat = 34
    private static let width: CGFloat = 340
    private static let maxVisible = 6

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.rowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none

        let root = CompletionList(model: model, onPick: { [weak self] item in
            self?.onCommit?(item)
        })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = panel.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    deinit {
        // 控制器随 Coordinator 一起被销毁时，必须把浮动面板收掉。
        // 否则切换笔记会留下一个孤立的空面板。
        panel.orderOut(nil)
        panel.contentView = nil
    }

    var isVisible: Bool { panel.isVisible }

    var selectedItem: CompletionItem? { model.current }

    func show(items: [CompletionItem], anchor: NSRect, in view: NSView, onCommit: @escaping (CompletionItem) -> Void) {
        guard !items.isEmpty else { hide(); return }
        DebugLog.write("panel.show items=\(items.count) anchor=\(anchor) hasWindow=\(view.window != nil)")
        self.onCommit = onCommit
        model.items = items
        model.selected = 0
        layout()

        guard let window = view.window else { return }
        let windowRect = view.convert(anchor, to: nil)
        let screenRect = window.convertToScreen(windowRect)

        var origin = NSPoint(x: screenRect.minX - 12, y: screenRect.minY - 6)
        // 贴到屏幕内
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + Self.width > visible.maxX { origin.x = visible.maxX - Self.width - 8 }
            if origin.x < visible.minX { origin.x = visible.minX + 8 }
        }

        panel.setFrame(NSRect(origin: NSPoint(x: origin.x, y: origin.y - height()), size: NSSize(width: Self.width, height: height())), display: false)
        panel.orderFront(nil)
        DebugLog.write("panel.shown frame=\(panel.frame) visible=\(panel.isVisible) screen=\(String(describing: window.screen?.visibleFrame))")
    }

    func update(items: [CompletionItem]) {
        guard !items.isEmpty else { hide(); return }
        model.items = items
        if model.selected >= items.count { model.selected = max(0, items.count - 1) }
        layout()
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: Self.width, height: height())), display: true)
    }

    func move(_ delta: Int) {
        model.move(delta)
    }

    func hide() {
        panel.orderOut(nil)
        onCommit = nil
    }

    private func height() -> CGFloat {
        let rows = min(max(model.items.count, 1), Self.maxVisible)
        return CGFloat(rows) * Self.rowHeight + 12
    }

    private func layout() {
        panel.contentView?.layoutSubtreeIfNeeded()
    }
}

private struct CompletionList: View {
    @ObservedObject var model: CompletionModel
    var onPick: (CompletionItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == model.selected)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(item) }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selected) { _, newValue in
                withAnimation(.none) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func row(_ item: CompletionItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.isCreate ? "plus.circle" : item.status.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(item.isCreate ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            Text(item.isCreate ? "新建《\(item.title)》" : item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if !item.isCreate {
                if item.backlinkCount > 0 {
                    Text("\(item.backlinkCount)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(item.status.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
    }
}
