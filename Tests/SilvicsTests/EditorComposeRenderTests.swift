import AppKit
import XCTest
@testable import Silvics

/// 编辑区渲染回归（issue #49）。
///
/// 症状：中文输入法组字时，待办复选框跑到别的行上，勾选态也跟着串行；
/// 组字的那一行同时露出 `- [ ]` 源码和复选框。
///
/// 根因：组字期间 `restyle` / `refreshSyntaxMarksForCaret` 都按 I01–I04 让路，
/// 因此 `listMarkers` 停在组字之前的偏移上；但 `layout()` 仍然会调
/// `relayoutTodoCheckboxes()`，拿过期偏移去算浮层位置 —— 偏移已经落在别的段落里，
/// 于是别的行的复选框被画到这一行，勾选态也取错。点击时 `lineLocation` 同样是过期值。
///
/// 这些用例守两条不变量：
/// 1. 复选框只出现在自己的待办行上（y 落在该段首行），勾选态与本行正文一致。
/// 2. 组字期间渲染冻结：已有正文的属性一个字都不许变。
///
/// 用例编号接 `docs/日记编辑器边界用例.md`：R01–R09。
@MainActor
final class EditorComposeRenderTests: XCTestCase {

    // MARK: - 造视图

    private struct Editor {
        let textView: EditorTextView
        let window: NSWindow
        let coordinator: NoteEditorView.Coordinator
    }

    private func makeEditor(_ text: String, caret: Int) -> Editor {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
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
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.restyle(force: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.layoutSubtreeIfNeeded()
        return Editor(textView: textView, window: window, coordinator: coordinator)
    }

    /// 行号（0 起）对应的段落起点。
    private func lineStart(_ text: String, _ line: Int) -> Int {
        let ns = text as NSString
        var offset = 0
        for _ in 0..<line {
            let newline = ns.range(of: "\n", range: NSRange(location: offset, length: ns.length - offset))
            guard newline.location != NSNotFound else { break }
            offset = newline.location + 1
        }
        return offset
    }

    /// 某字符所在段落第一视觉行的 y（视图坐标）。与 `relayoutTodoCheckboxes` 无关，独立量。
    private func lineY(_ textView: EditorTextView, at index: Int) -> CGFloat? {
        guard let manager = textView.textLayoutManager, let storage = textView.textStorage,
              storage.length > 0 else { return nil }
        let ns = textView.string as NSString
        let clamped = min(max(0, index), ns.length - 1)
        let paragraph = ns.paragraphRange(for: NSRange(location: clamped, length: 0))
        let document = manager.documentRange
        guard let start = manager.location(document.location, offsetBy: paragraph.location),
              let end = manager.location(start, offsetBy: paragraph.length),
              let range = NSTextRange(location: start, end: end) else { return nil }
        manager.ensureLayout(for: range)
        var top: CGFloat?
        manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            if top == nil || frame.minY < top! { top = frame.minY }
            return true
        }
        guard let top else { return nil }
        return textView.textContainerOrigin.y + top
    }

    /// 组合一次：只走 `setMarkedText`，不提交。
    private func compose(_ textView: EditorTextView, _ pinyin: String) {
        textView.setMarkedText(
            pinyin,
            selectedRange: NSRange(location: (pinyin as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    /// 正文属性的摘要：位置、长度、字号、kern、字色。组字前后必须一模一样。
    private func attributeDigest(_ textView: EditorTextView, length: Int) -> String {
        guard let storage = textView.textStorage else { return "no-storage" }
        let limit = min(length, storage.length)
        guard limit > 0 else { return "" }
        var parts: [String] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: limit), options: []) { attrs, range, _ in
            let font = (attrs[.font] as? NSFont)?.pointSize ?? -1
            let kern = (attrs[.kern] as? CGFloat).map { String(format: "%.4f", $0) } ?? "-"
            let color = (attrs[.foregroundColor] as? NSColor)?.description ?? "-"
            parts.append("\(range.location)+\(range.length):\(font):\(kern):\(color)")
        }
        return parts.joined(separator: " ")
    }

    /// 待办行的期望浮层：位置来自正文解析，状态来自 `[ ]` / `[x]`。
    private struct ExpectedBox {
        var marker: ListMarker
        var y: CGFloat
        var checked: Bool
    }

    private func expectedBoxes(_ editor: Editor, caretParagraph: NSRange?) -> [ExpectedBox] {
        var out: [ExpectedBox] = []
        for marker in MarkdownStyler.listMarkers(in: editor.textView.string) where marker.isTodo {
            if ListLayout.isInCaretParagraph(marker, caretParagraph) { continue }
            guard let y = lineY(editor.textView, at: marker.markerRange.location) else { continue }
            guard editor.textView.visibleRect.insetBy(dx: 0, dy: -60).intersects(
                NSRect(x: 0, y: y, width: 10, height: ListLayout.checkboxSize)
            ) else { continue }
            out.append(ExpectedBox(marker: marker, y: y, checked: marker.kind == .todo(checked: true)))
        }
        return out
    }

    /// 复选浮层对账：数量、所在行、勾选态三项全对才算通过。
    private func assertBoxesMatchText(
        _ editor: Editor,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = expectedBoxes(editor, caretParagraph: editor.textView.caretParagraph)
        let actual = editor.textView.todoCheckboxItems
        XCTAssertEqual(actual.count, expected.count, "\(label)：复选框数量与本段待办数不一致", file: file, line: line)
        for item in expected {
            let match = actual.first { abs($0.frame.minY - item.y) <= 4 }
            guard let match else {
                XCTFail("\(label)：行首 \(item.marker.markerRange.location) 的待办没有复选框"
                    + "（期望 y=\(Int(item.y))，实际 \(actual.map { Int($0.frame.minY) })）",
                    file: file, line: line)
                continue
            }
            XCTAssertEqual(match.checked, item.checked,
                           "\(label)：行首 \(item.marker.markerRange.location) 的勾选态取错",
                           file: file, line: line)
        }
    }

    private func document() -> String {
        """
        # 锻炼
        - [ ] 甲

        ## 生活
        - [x] 乙

        ## 工作
        - [x] 丙
          - [ ] 丁

        # 日记
        """
    }

    // MARK: - R01–R03 组合期浮层不许串行

    /// R01：组字把后面的行下移时，其余行的复选框必须留在自己的行上。
    ///
    /// 旧实现：`layout()` 用组字前的偏移重排，偏移落到下一段，复选框整体上窜一行。
    func testCheckboxesStayOnTheirOwnLinesDuringComposition() {
        let text = document()
        let caret = lineStart(text, 1) + ("- [ ] 甲" as NSString).length
        let editor = makeEditor(text, caret: caret)
        assertBoxesMatchText(editor, "组字前")

        compose(editor.textView, "nihao")
        editor.textView.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.textView.hasMarkedText(), "这话得在组合态里做")
        assertBoxesMatchText(editor, "组字中")
    }

    /// R02：组字期间每来一次布局都得是同一种结果，不能越排越偏。
    func testCheckboxLayoutIsIdempotentDuringComposition() {
        let text = document()
        let caret = lineStart(text, 1) + ("- [ ] 甲" as NSString).length
        let editor = makeEditor(text, caret: caret)
        compose(editor.textView, "qia'yao'j")
        editor.textView.layoutSubtreeIfNeeded()
        let first = editor.textView.todoCheckboxItems.map { "\($0.location)|\($0.checked)|\(Int($0.frame.minY))" }

        for _ in 0..<3 {
            editor.textView.needsLayout = true
            editor.textView.layoutSubtreeIfNeeded()
        }
        let later = editor.textView.todoCheckboxItems.map { "\($0.location)|\($0.checked)|\(Int($0.frame.minY))" }
        XCTAssertEqual(later, first, "组合态里重复布局，复选框位置/状态被改动")
        assertBoxesMatchText(editor, "组合中重复布局")
    }

    /// R03：上屏之后必须回到渲染态，且浮层与正文对齐。
    func testCheckboxesRecoverAfterCommit() {
        let text = document()
        let caret = lineStart(text, 1) + ("- [ ] 甲" as NSString).length
        let editor = makeEditor(text, caret: caret)
        compose(editor.textView, "nihao")
        editor.textView.insertText("髂腰肌", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.layoutSubtreeIfNeeded()
        XCTAssertFalse(editor.textView.hasMarkedText())
        assertBoxesMatchText(editor, "上屏后")
        XCTAssertTrue(editor.textView.string.contains("髂腰肌"), "正文里应留下上屏的词")
    }

    /// R07：组字串长到换行、把下面的行挤下去时，浮层要跟着下移。
    ///
    /// 组字不改正文通知（`textDidChange` 不响），所以「组字期间补标记」必须在
    /// `setMarkedText` 这个入口做。否则浮层会停在原位，跟正文字错行。
    func testCheckboxesFollowTextWhenCompositionWrapsLine() {
        let text = document()
        let caret = lineStart(text, 1) + ("- [ ] 甲" as NSString).length
        let editor = makeEditor(text, caret: caret)
        let before = editor.textView.todoCheckboxItems.map { Int($0.frame.minY) }

        compose(editor.textView, String(repeating: "zhongguoren", count: 6))
        editor.textView.layoutSubtreeIfNeeded()

        XCTAssertEqual(editor.textView.listMarkers, MarkdownStyler.listMarkers(in: editor.textView.string),
                       "组字期间视图持有的标记要跟得上正文")
        assertBoxesMatchText(editor, "组字换行后")
        let after = editor.textView.todoCheckboxItems.map { Int($0.frame.minY) }
        XCTAssertNotEqual(after, before, "组字把行挤下去之后，浮层不该停在原位")
    }

    // MARK: - R04–R05 组合期渲染冻结（覆盖全部 markdown 组件）

    /// 组字期间已有正文的属性一个都不许变。
    ///
    /// 旧实现里 `restyle` 已经会让路，但 `layout()` 引出的复选框重排不受管，
    /// 所以这条断言现在只差浮层一项；改成属性摘要后任何渲染改动都会红。
    func testCompositionFreezesRendering() {
        let text = document()
        let caret = (text as NSString).length
        let editor = makeEditor(text, caret: caret)
        let before = attributeDigest(editor.textView, length: (text as NSString).length)
        let boxesBefore = editor.textView.todoCheckboxItems.map { $0.location }

        compose(editor.textView, "qia'yao'j")
        editor.textView.layoutSubtreeIfNeeded()

        let after = attributeDigest(editor.textView, length: (text as NSString).length)
        XCTAssertEqual(after, before, "组字期间正文属性被改动")
        XCTAssertEqual(editor.textView.todoCheckboxItems.map { $0.location }, boxesBefore,
                       "组字期间复选框被重排")
    }

    /// 组件矩阵：每种 markdown 结构都要经得住「组字期间不动渲染」。
    func testCompositionFreezesRenderingForEveryComponent() {
        let cases: [(name: String, line: String)] = [
            ("标题", "## 二级标题"),
            ("无序列表", "- 甲"),
            ("有序列表", "3. 丙"),
            ("待办", "- [ ] 戊"),
            ("已完成待办", "- [x] 己"),
            ("嵌套待办", "  - [ ] 庚"),
            ("引用", "> 辛"),
            ("表格", "| 列一 | 列二 |\n| --- | --- |\n| 甲 | 乙 |"),
            ("代码块", "```swift\nlet a = 1\n```"),
            ("行内代码与粗斜体", "**粗** *斜* `code`"),
            ("引用链接", "见 [[甲]] 与 [[乙|别名]]"),
            ("水平线", "---")
        ]
        for item in cases {
            let text = "起始段落。\n\(item.line)\n末尾段落。"
            // 光标停在末尾段落：上面这些结构都按渲染态显示，组字发生在它们之后。
            let caret = lineStart(text, item.line.contains("\n") ? 4 : 2)
                + ("末尾段落。" as NSString).length
            let editor = makeEditor(text, caret: caret)
            let length = (text as NSString).length
            let before = attributeDigest(editor.textView, length: length)

            compose(editor.textView, "nihao")
            editor.textView.layoutSubtreeIfNeeded()

            XCTAssertTrue(editor.textView.hasMarkedText(), "\(item.name)：没进组合态")
            XCTAssertEqual(attributeDigest(editor.textView, length: length), before,
                           "\(item.name)：组字期间渲染被改动")

            editor.textView.insertText("词", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.textView.layoutSubtreeIfNeeded()
            XCTAssertEqual(editor.textView.string, text + "词", "\(item.name)：上屏后正文不对")
            XCTAssertTrue(editor.textView.string.contains(item.line.components(separatedBy: "\n")[0]),
                          "\(item.name)：原有行被改坏")
        }
    }

    /// R08：块级装饰的区间（引用竖线、代码块底色、列表标记）也必须跟着正文走。
    ///
    /// 这些装饰都是按字符偏移自绘的：偏移停在组字前，竖线就会画到上一段去。
    /// 复选框只是最先被看见的那一个（issue #49），同一个根因要一起守住。
    func testBlockDecorationsFollowTextDuringComposition() {
        let text = """
        起始段落。
        结尾段落。
        > 引用一行
        > 引用两行

        ```swift
        let a = 1
        ```

        - 列表项
        """
        let caret = lineStart(text, 1) + ("结尾段落。" as NSString).length
        let editor = makeEditor(text, caret: caret)
        let before = MarkdownStyler.analyze(text)
        XCTAssertEqual(editor.textView.quoteRanges, before.blockQuotes, "前置条件：初始状态就对得上")

        compose(editor.textView, String(repeating: "zhongguoren", count: 6))
        editor.textView.layoutSubtreeIfNeeded()

        let now = editor.textView.string
        XCTAssertTrue(editor.textView.hasMarkedText())
        let spans = MarkdownStyler.analyze(now)
        XCTAssertEqual(editor.textView.quoteRanges, spans.blockQuotes, "组字期间引用竖线区间过期")
        XCTAssertEqual(editor.textView.codeBlockRanges, spans.codeBlocks, "组字期间代码块底色区间过期")
        XCTAssertEqual(editor.textView.listMarkers, MarkdownStyler.listMarkers(in: now),
                       "组字期间列表标记区间过期")
    }

    // MARK: - R06 光标段落露源码，且不画复选框（S40 回归）

    func testCaretParagraphShowsSourceWithoutCheckbox() {
        let text = document()
        let caret = lineStart(text, 1) + 2
        let editor = makeEditor(text, caret: caret)
        let markers = MarkdownStyler.listMarkers(in: text)
        guard let firstTodo = markers.first(where: { $0.markerRange.location == lineStart(text, 1) }) else {
            return XCTFail("没识别出第一条待办")
        }
        let font = editor.textView.textStorage?.attribute(.font, at: firstTodo.markerRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize ?? 0, Theme.bodyFont.pointSize, accuracy: 0.01, "光标段落标记要恢复原字号")
        XCTAssertTrue(editor.textView.todoCheckboxItems.allSatisfy { $0.location != firstTodo.markerRange.location },
                      "光标段落不画复选框")
        assertBoxesMatchText(editor, "光标在待办行")
    }
}
