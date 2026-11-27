import AppKit
import XCTest
@testable import Silvics

/// 渲染 / 编辑态的几何不变性（对齐 Typora 的展示规则）。
///
/// 判据一句话：**块级标记永远不参与排版**，光标进出任何一行，正文 x 都不该变；
/// 行内标记只在光标落进这一段时恢复原宽。
final class EditorTyporaModeTests: XCTestCase {

    // MARK: - 工具

    private func makeEditor(_ text: String) -> (EditorTextView, NSWindow, NoteEditorView.Coordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 28, height: 24)
        scrollView.documentView = textView
        window.contentView = scrollView
        textView.string = text

        let parent = NoteEditorView(
            initialText: text,
            text: text,
            resolvedKeys: [],
            mentions: [],
            appearance: AppearanceSettings(),
            editable: true,
            rendersWikiLinks: true,
            onChange: { _ in },
            completionProvider: { _, _ in [] },
            onCreateNote: { _ in nil },
            onOpenLink: { _ in }
        )
        let coordinator = parent.makeCoordinator()
        coordinator.wire(textView: textView)
        coordinator.attach(textView: textView, scrollView: scrollView)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        coordinator.restyle(force: true)
        textView.layoutSubtreeIfNeeded()
        return (textView, window, coordinator)
    }

    /// 字符 `index` 在视图坐标里的 x。
    private func characterX(_ textView: EditorTextView, at index: Int) -> CGFloat? {
        guard let manager = textView.textLayoutManager else { return nil }
        let ns = textView.string as NSString
        guard ns.length > 0 else { return nil }
        let clamped = min(max(0, index), ns.length - 1)
        guard let location = manager.location(manager.documentRange.location, offsetBy: clamped),
              let fragment = manager.textLayoutFragment(for: location) else { return nil }
        let paragraphStart = ns.paragraphRange(for: NSRange(location: clamped, length: 0)).location
        var base = 0
        for lineFragment in fragment.textLineFragments {
            let length = lineFragment.characterRange.length
            if clamped >= paragraphStart + base, clamped < paragraphStart + base + length {
                let point = lineFragment.locationForCharacter(at: clamped - paragraphStart - base)
                return textView.textContainerOrigin.x + fragment.layoutFragmentFrame.minX + point.x
            }
            base += length
        }
        return nil
    }

    private func fontSize(_ textView: EditorTextView, at index: Int) -> CGFloat? {
        guard let storage = textView.textStorage, index < storage.length else { return nil }
        return (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize
    }

    private func setCaret(_ location: Int, _ textView: EditorTextView, _ coordinator: NoteEditorView.Coordinator) {
        textView.setSelectedRange(NSRange(location: min(location, (textView.string as NSString).length), length: 0))
        coordinator.restyle(force: true)
        textView.layoutSubtreeIfNeeded()
    }

    // MARK: - 块级标记：永不参与排版

    func testHeadingMarkerNeverTakesWidth() {
        let text = "## 甲标题\n\n正文一段。"
        let (textView, _, coordinator) = makeEditor(text)
        let before = characterX(textView, at: 3)!
        setCaret(5, textView, coordinator)
        XCTAssertEqual(characterX(textView, at: 3)!, before, accuracy: 0.5, "光标进标题行，正文 x 不该变")
        XCTAssertLessThan(fontSize(textView, at: 0)!, 1, "`##` 不该因为光标而露出")
        XCTAssertLessThan(fontSize(textView, at: 1)!, 1)
    }

    func testListMarkerNeverTakesWidth() {
        let text = "- 甲条目\n\n正文一段。"
        let (textView, _, coordinator) = makeEditor(text)
        let before = characterX(textView, at: 2)!
        setCaret(4, textView, coordinator)
        XCTAssertEqual(characterX(textView, at: 2)!, before, accuracy: 0.5, "光标进列表行，正文 x 不该变")
        XCTAssertLessThan(fontSize(textView, at: 0)!, 1)
    }

    func testTodoMarkerNeverTakesWidthAndCheckboxStays() {
        let text = "- [ ] 甲待办\n\n正文一段。"
        let (textView, _, coordinator) = makeEditor(text)
        let before = characterX(textView, at: 6)!
        setCaret(8, textView, coordinator)
        XCTAssertEqual(characterX(textView, at: 6)!, before, accuracy: 0.5, "光标进待办行，正文 x 不该变")
        XCTAssertLessThan(fontSize(textView, at: 0)!, 1)
        XCTAssertEqual(textView.todoCheckboxItems.count, 1, "光标在这一行时复选框也还在")
    }

    func testQuoteEveryLinePrefixIsCompressed() {
        let text = "> 甲行\n> 乙行\n\n正文一段。"
        let (textView, _, _) = makeEditor(text)
        let first = characterX(textView, at: 2)!
        let second = characterX(textView, at: 6)!
        XCTAssertEqual(first, second, accuracy: 0.5, "多行引用第二行不该比第一行右移")
    }

    // MARK: - 行内标记：渲染态零宽，光标进段才露

    func testInlineMarkersAreCollapsedWhenCaretElsewhere() {
        let text = "前文有**加粗**在句中。\n\n正文一段。"
        let (textView, _, _) = makeEditor(text)
        let marker = ("前文有" as NSString).length
        XCTAssertLessThan(fontSize(textView, at: marker)!, 1, "渲染态 `**` 要压宽")
        XCTAssertLessThan(fontSize(textView, at: marker + 1)!, 1)
    }

    func testInlineMarkersRevealWhenCaretInsideSpan() {
        let text = "前文有**加粗**在句中。\n\n正文一段。"
        let (textView, _, coordinator) = makeEditor(text)
        let marker = ("前文有" as NSString).length
        setCaret(("前文有**加粗" as NSString).length, textView, coordinator)
        XCTAssertGreaterThan(fontSize(textView, at: marker)!, 1, "光标在粗体里要露出 `**`")
    }

    /// 渲染态不该在内联标记处留下空洞：`**加粗**` 的两个前缀加起来 ≈ 0 宽。
    func testNoPhantomGapFromInlineMarkers() {
        let plain = "前文有加粗在句中。"
        let marked = "前文有**加粗**在句中。"
        let (plainView, _, _) = makeEditor(plain)
        let (markedView, _, _) = makeEditor(marked)
        let plainX = characterX(plainView, at: ("前文有" as NSString).length)!
        let markedX = characterX(markedView, at: ("前文有**" as NSString).length)!
        XCTAssertEqual(markedX, plainX, accuracy: 0.5, "压宽后正文位置应与无标记时一致")
    }

    // MARK: - 源码模式（⌘/）：所有标记恢复原宽

    func testSourceModeRevealsEveryMarker() {
        let text = "## 甲标题\n\n- 甲条目\n- [ ] 甲待办\n\n> 甲引用\n\n```swift\nlet a = 1\n```\n"
        let (textView, _, coordinator) = makeEditor(text)
        textView.showsSource = true
        coordinator.restyle(force: true)
        textView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(fontSize(textView, at: 0)!, 1, "源码模式：`##` 要露出来")
        let listStart = ("## 甲标题\n\n" as NSString).length
        XCTAssertGreaterThan(fontSize(textView, at: listStart)!, 1, "源码模式：`- ` 要露出来")
        let fenceStart = ("## 甲标题\n\n- 甲条目\n- [ ] 甲待办\n\n> 甲引用\n\n" as NSString).length
        XCTAssertGreaterThan(fontSize(textView, at: fenceStart)!, 1, "源码模式：围栏行要露出来")
        // 回切渲染模式：重新压宽。
        textView.showsSource = false
        coordinator.restyle(force: true)
        textView.layoutSubtreeIfNeeded()
        XCTAssertLessThan(fontSize(textView, at: 0)!, 1)
    }

    // MARK: - 围栏行与分隔行

    func testCodeFenceLineIsCollapsed() {
        let text = "```swift\nlet a = 1\n```\n\n正文一段。"
        let (textView, _, _) = makeEditor(text)
        XCTAssertLessThan(fontSize(textView, at: 0)!, 1, "围栏行整行渲染态折殁")
    }

    /// 分隔行：整行透明 + 行高 1pt，但字宽不动（pipe 是各列的横向基准）。
    func testTableDelimiterRowIsInvisibleAndFlat() {
        let text = "| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |\n\n正文一段。"
        let (textView, _, _) = makeEditor(text)
        let delimiterStart = ("| 甲 | 乙 |\n" as NSString).length
        let color = textView.textStorage?.attribute(.foregroundColor, at: delimiterStart, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .clear, "分隔行渲染态要看不见")
        let style = textView.textStorage?.attribute(.paragraphStyle, at: delimiterStart, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.maximumLineHeight ?? -1, 1, accuracy: 0.01, "分隔行要压扁，不能占一整行")
        XCTAssertEqual(style?.minimumLineHeight ?? -1, 1, accuracy: 0.01)
    }
}
