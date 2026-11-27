import AppKit
import XCTest
@testable import Silvics

/// 列表 / 待办 / 引用的识别与渲染。
///
/// 编号按 `docs/日记编辑器边界用例.md` 扩展：S28–S41。
/// 两个层次：
/// - 识别与分组是纯函数（`MarkdownStyler.listMarkers`、`ListLayout`、`Theme` 的属性构造）。
/// - 宽度、对齐、复选框位置用真的 `NSTextView`（TextKit 2）量，不看属性表猜。
final class ListRenderingTests: XCTestCase {

    // MARK: - 工具

    private func paragraph(_ text: String, line: Int) -> NSRange {
        let ns = text as NSString
        var offset = 0
        var current = 0
        while current < line {
            let newline = ns.range(
                of: "\n",
                options: [],
                range: NSRange(location: offset, length: ns.length - offset)
            )
            guard newline.location != NSNotFound else { break }
            offset = newline.location + 1
            current += 1
        }
        return ns.paragraphRange(for: NSRange(location: offset, length: 0))
    }

    private func markers(_ text: String) -> [ListMarker] {
        MarkdownStyler.listMarkers(in: text)
    }

    /// 造一个真的 TextKit 2 文本视图并把正文装进去。
    private func makeTextView(_ text: String) -> (EditorTextView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 28, height: 24)
        scrollView.documentView = textView
        window.contentView = scrollView
        textView.string = text
        textView.layoutSubtreeIfNeeded()
        return (textView, window)
    }

    /// 某行首字（跳过行首标记）在视图坐标里的 x。
    ///
    /// 不能用 `enumerateTextSegments` 的 `frame.minX`：那是行片段原点（固定等于缩进处），
    /// 标记是否压宽根本反映不出来。这里取「标记后第一个字符」的基线位置。
    private func textStartX(_ textView: EditorTextView, line: Int) -> CGFloat? {
        let ns = textView.string as NSString
        var start = 0
        for _ in 0..<line {
            let newline = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            guard newline.location != NSNotFound else { return nil }
            start = newline.location + 1
        }
        let skip = MarkdownStyler.listMarkers(in: textView.string)
            .first { $0.markerRange.location == start }?
            .markerRange.length ?? 0
        return characterX(textView, at: start + skip)
    }

    /// 字符 `index` 在视图坐标里的 x（按段落相对偏移找视觉行）。
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

    /// 该行的前缀是否被压宽成「看不见」：首字位置 ≈ 缩进处。
    private func assertMarkerCompressed(
        _ textView: EditorTextView,
        line lineIndex: Int,
        file: StaticString = #filePath,
        lineNumber: UInt = #line
    ) {
        let origin = textView.textContainerOrigin.x
        let expected = origin + 5 + ListLayout.indent // 5 = lineFragmentPadding
        let got = textStartX(textView, line: lineIndex)
        XCTAssertNotNil(got, file: file, line: lineNumber)
        XCTAssertEqual(
            got ?? -1,
            expected,
            accuracy: 0.5,
            "标记压宽后正文应从缩进处开始（实际 \(got ?? -1)，期望 \(expected)）",
            file: file,
            line: lineNumber
        )
    }

    // MARK: - S28 / S29 无序列表

    func testS28DashWithSpaceIsUnorderedList() {
        let text = "- 甲"
        let list = markers(text)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.kind, .unordered)
        XCTAssertEqual(list.first?.markerRange, NSRange(location: 0, length: 2), "标记含项目符号与其后空格")
        XCTAssertEqual((text as NSString).substring(with: list[0].visibleRange), "- ")
        XCTAssertEqual((text as NSString).substring(from: 2), "甲")
    }

    func testS29DashWithoutSpaceIsNotList() {
        XCTAssertTrue(markers("-甲").isEmpty, "`-` 后无空格不算列表")
        XCTAssertTrue(markers("*甲").isEmpty)
        XCTAssertTrue(markers("+甲").isEmpty)
        XCTAssertTrue(markers("---").isEmpty, "三个及以上连字符是分隔线，不是列表")
    }

    // MARK: - S30 / S31 / S32 有序列表

    func testS30NumberDotWithSpaceIsOrderedList() {
        let text = "1. 甲"
        let list = markers(text)
        XCTAssertEqual(list.first?.kind, .ordered(1))
        XCTAssertEqual(list.first?.markerRange, NSRange(location: 0, length: 3))
        XCTAssertEqual((text as NSString).substring(with: list[0].visibleRange), "1. ")
    }

    func testS31NumberDotWithoutSpaceIsNotList() {
        XCTAssertTrue(markers("1.甲").isEmpty, "`.` 后无空格不算列表")
        XCTAssertTrue(markers("1)甲").isEmpty)
    }

    func testS32MultiDigitOrderedKeepsOriginalNumber() {
        let list = markers("10. 甲")
        XCTAssertEqual(list.first?.kind, .ordered(10))
        XCTAssertEqual(list.first?.orderedNumber, 10)
        XCTAssertEqual(list.first?.markerRange, NSRange(location: 0, length: 4))
    }

    func testS30ParenDelimiterAlsoOrdered() {
        XCTAssertEqual(markers("3) 甲").first?.kind, .ordered(3))
    }

    // MARK: - S33 代码块里不是列表

    func testS33DashedLineInsideCodeBlockIsNotList() {
        let text = "```\n- 甲\n```\n- 乙"
        let list = markers(text)
        XCTAssertEqual(list.count, 1, "围栏内的 `- 甲` 不算列表，围栏后的 `- 乙` 算")
        XCTAssertEqual(list.first?.markerRange.location, 12, "只有最后一行是列表（前面三行依次是围栏、块内容、闭围栏）")
        XCTAssertEqual(list.first?.kind, .unordered)
    }

    // MARK: - S34 待办优先于无序列表

    func testS34TodoWinsOverUnordered() {
        let text = "- [ ] 甲"
        let list = markers(text)
        XCTAssertEqual(list.count, 1, "一行只产出一条列表标记")
        XCTAssertEqual(list.first?.kind, .todo(checked: false))
        XCTAssertEqual(list.first?.markerRange, NSRange(location: 0, length: 6), "待办标记整段含勾选框")

        let done = markers("- [x] 甲")
        XCTAssertEqual(done.first?.kind, .todo(checked: true))

        // 语法标记同样只出一条：`- [ ] `，不会退化成 `- `
        let vis = MarkdownStyler.syntaxMarkerRanges(in: text, caretParagraph: nil)
        XCTAssertEqual(vis.all, [NSRange(location: 0, length: 6)])
    }

    // MARK: - S35 缩进

    func testS35IndentedListStillRecognizedAndRecordsIndent() {
        let text = "  - 甲"
        let list = markers(text)
        XCTAssertEqual(list.count, 1, "缩进两格仍是列表")
        XCTAssertEqual(list.first?.indent, 2, "缩进量要记下来")
        XCTAssertEqual(list.first?.markerRange, NSRange(location: 0, length: 4), "压宽范围含缩进")
        XCTAssertEqual(list.first?.visibleRange, NSRange(location: 2, length: 2), "语法标记从项目符号开始，不含缩进")

        let todo = markers("    - [ ] 甲")
        XCTAssertEqual(todo.first?.indent, 4)
        XCTAssertEqual(todo.first?.kind, .todo(checked: false))
        XCTAssertEqual(todo.first?.visibleRange.location, 4)
    }

    // MARK: - S36 隐藏态标记宽度 < 0.5pt

    func testS36CompressedMarkerIsNarrowerThanHalfPoint() {
        for marker in ["- ", "1. ", "10. ", "- [ ] ", "- [x] ", "> "] {
            let attributed = NSAttributedString(
                string: marker,
                attributes: Theme.compressedMarkerAttributes(for: marker)
            )
            let width = attributed.size().width
            XCTAssertLessThan(width, 0.5, "隐藏态「\(marker)」总宽应 ≈0，实际 \(width)")
        }
        // 对照：不压缩时明显更宽，证明上面不是恒真
        let visible = NSAttributedString(string: "- ", attributes: Theme.visibleMarkerAttributes())
        XCTAssertGreaterThan(visible.size().width, 5)
    }

    func testS36KernIsNegativeAndCached() {
        let kern = Theme.compressedMarkerKern(for: "- [ ] ")
        XCTAssertLessThan(kern, 0)
        XCTAssertEqual(kern, Theme.compressedMarkerKern(for: "- [ ] "), "同一标记的 kern 要复用，不重复测量")

        // 真排一遍：列表第二行正文从缩进处开始，软换行后仍对齐。
        let long = String(repeating: "甲乙丙丁戊己庚辛", count: 6)
        let text = "- \(long)"
        let (textView, _) = makeTextView(text)
        applyListMarkers(text, to: textView, caretParagraph: nil)
        textView.layoutSubtreeIfNeeded()

        assertMarkerCompressed(textView, line: 0)

        // 软换行：两条视觉行左缘一致
        guard let manager = textView.textLayoutManager else { return XCTFail("no text layout manager") }
        let full = manager.documentRange
        manager.ensureLayout(for: full)
        var lefts: [CGFloat] = []
        manager.enumerateTextSegments(in: full, type: .standard, options: []) { _, frame, _, _ in
            lefts.append(frame.minX)
            return true
        }
        XCTAssertGreaterThanOrEqual(lefts.count, 2, "这条列表要能换行，否则测不到对齐")
        for left in lefts {
            XCTAssertEqual(left, lefts[0], accuracy: 0.1, "软换行后每一行的左缘必须与首行一致")
        }
    }

    // MARK: - S37 光标段落恢复正常宽度

    func testS37CaretParagraphRestoresMarkerWidth() {
        let text = "- 甲\n- 乙"
        let caret = paragraph(text, line: 0)

        // 属性层：光标段落用正文字号、没有 kern
        let visible = Theme.visibleMarkerAttributes()
        XCTAssertEqual(visible[.font] as? NSFont, Theme.bodyFont)
        XCTAssertNil(visible[.kern])

        // 布局层：光标段落的首字退到标记之后
        let (textView, _) = makeTextView(text)
        applyListMarkers(text, to: textView, caretParagraph: caret)
        textView.layoutSubtreeIfNeeded()

        let compressedStart = textView.textContainerOrigin.x + 5 + ListLayout.indent
        let caretLine = textStartX(textView, line: 0) ?? -1
        let renderedLine = textStartX(textView, line: 1) ?? -1
        XCTAssertEqual(caretLine, compressedStart + Theme.visibleMarkerWidth("- "), accuracy: 1,
                       "光标段落正文要往右让出标记宽度（实际 \(caretLine)）")
        XCTAssertGreaterThan(caretLine, renderedLine + 5, "光标段落的标记不压宽，比渲染段明显更靠右")
        assertMarkerCompressed(textView, line: 1)

        // 标记本身的字符一个没少
        XCTAssertEqual(textView.string, text)
        XCTAssertEqual(textView.textStorage?.length, (text as NSString).length)
    }

    func testS37IncrementalCaretRefreshSwitchesWidth() {
        // 纯分组：光标换段只换桶，标记集合不变。
        let text = "- 甲\n- 乙\n- 丙"
        let all = MarkdownStyler.syntaxMarkerRanges(in: text, caretParagraph: nil).all
        let showOnSecond = MarkdownStyler.split(all, caretParagraph: paragraph(text, line: 1))
        XCTAssertEqual(showOnSecond.show.count, 1)
        XCTAssertEqual(showOnSecond.hide.count, 2)
        XCTAssertEqual((text as NSString).substring(with: showOnSecond.show[0]), "- ")
    }

    // MARK: - S38 有序列表用原文序号

    func testS38OrderedKeepsOriginalNumbers() {
        let text = "1. 甲\n2. 乙\n10. 丙"
        let list = markers(text)
        XCTAssertEqual(list.map(\.orderedNumber), [1, 2, 10], "渲染用原序号，不重排也不补齐")

        // 序号数字本身不参与重排：标记区间就是原文 `10. `
        XCTAssertEqual((text as NSString).substring(with: list[2].visibleRange), "10. ")
    }

    // MARK: - S39 勾选切换与撤销

    func testS39ToggleTodoChangesTextAndUndoes() {
        let text = "- [ ] 甲\n- [x] 乙"
        let (textView, window) = makeTextView(text)
        let undo = UndoManager()
        let delegate = UndoDelegate(manager: undo)
        textView.delegate = delegate
        textView.allowsUndo = true
        window.makeFirstResponder(textView)

        XCTAssertTrue(textView.toggleTodo(at: 0), "第一行未完成 → 完成")
        XCTAssertEqual(textView.string, "- [x] 甲\n- [x] 乙", "只改中括号里那一个字符")

        XCTAssertTrue(undo.canUndo, "勾选要能撤销")
        undo.undo()
        XCTAssertEqual(textView.string, text, "撤销后回到原文")

        XCTAssertTrue(textView.toggleTodo(at: 10), "第二行已完成 → 未完成")
        XCTAssertEqual(textView.string, "- [ ] 甲\n- [ ] 乙")
    }

    func testS39CheckboxClickTogglesText() {
        // 真的点一下浮层复选框：target/action 接线、正文改写、状态刷新都要通。
        let (editor, _) = makeEditor("- [ ] 甲\n- [x] 乙")
        editor.setListMarkers(MarkdownStyler.listMarkers(in: editor.string), parsedFrom: editor.string)
        editor.caretParagraph = nil
        editor.layoutSubtreeIfNeeded()

        let boxes = editor.subviews.compactMap { $0 as? TodoCheckbox }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(boxes.count, 2, "两条待办各一个方框")
        XCTAssertFalse(boxes[0].isChecked)
        XCTAssertTrue(boxes[1].isChecked)

        boxes[0].performClick(nil)
        XCTAssertEqual(editor.string, "- [x] 甲\n- [x] 乙", "点击方框要改正文的 `[ ]` → `[x]`")

        editor.layoutSubtreeIfNeeded()
        let after = editor.subviews.compactMap { $0 as? TodoCheckbox }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertTrue(after[0].isChecked, "勾完外观要跟着变")
    }

    func testS39ToggleOnEditorSurfaceRegistersUndo() {
        // 走的是 `EditorTextView.toggleTodo` 本身，不是测试另写的函数。
        let (editor, window) = makeEditor("- [ ] 甲")
        let undo = UndoManager()
        let delegate = UndoDelegate(manager: undo)
        editor.delegate = delegate
        editor.allowsUndo = true
        window.makeFirstResponder(editor)
        XCTAssertTrue(editor.toggleTodo(at: 0))
        XCTAssertEqual(editor.string, "- [x] 甲")
        XCTAssertTrue(undo.canUndo, "编辑区自身的勾选也要能撤销")
        undo.undo()
        XCTAssertEqual(editor.string, "- [ ] 甲")
    }

    // MARK: - S40 光标行不画复选框

    func testS40CaretParagraphHasNoCheckbox() {
        let text = "- [ ] 甲\n- [x] 乙"
        let list = markers(text)

        // 纯分组：光标在第一段时，只有第二行要画复选框
        let caretFirst = ListLayout.checkboxTodos(list, caretParagraph: paragraph(text, line: 0))
        XCTAssertEqual(caretFirst.count, 1)
        XCTAssertEqual(caretFirst.first?.markerRange.location, paragraph(text, line: 1).location)

        let noCaret = ListLayout.checkboxTodos(list, caretParagraph: nil)
        XCTAssertEqual(noCaret.count, 2)

        // 渲染层：光标段落不出现 NSButton，移开后补上
        let (editor, _) = makeEditor(text)
        editor.setListMarkers(list, parsedFrom: text)
        editor.caretParagraph = paragraph(text, line: 0)
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.todoCheckboxCount, 1, "光标段落的待办不画方框，露源码")
        editor.caretParagraph = paragraph(text, line: 1)
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.todoCheckboxCount, 1)
        editor.caretParagraph = nil
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.todoCheckboxCount, 2)
    }

    func testS40CheckboxSitsLeftOfTextAndCentersOnLine() {
        let text = "- [x] 甲\n\n正文"
        let (editor, _) = makeEditor(text)
        editor.setListMarkers(markers(text), parsedFrom: text)
        editor.caretParagraph = paragraph(text, line: 2)
        editor.layoutSubtreeIfNeeded()
        guard let box = editor.todoCheckboxFrames.first else {
            return XCTFail("没有复选框")
        }
        let textStart = textViewTextStart(editor, line: 0) ?? -1
        XCTAssertGreaterThan(textStart, box.maxX, "方框要在正文左侧，不能压住文字")
        XCTAssertLessThan(box.maxX, textStart, "方框右缘与文字之间要有间隔")
        XCTAssertEqual(box.width, ListLayout.checkboxSize, accuracy: 0.1)
    }

    // MARK: - S41 列表项里的加粗

    func testS41BoldInsideListItemKeepsMarkerSeparate() {
        let text = "- 前缀 **加粗** 尾巴"
        let list = markers(text)
        XCTAssertEqual(list.first?.kind, .unordered)
        XCTAssertEqual((text as NSString).substring(with: list[0].visibleRange), "- ")

        // 加粗区间不含项目符号
        let spans = MarkdownStyler.analyze(text)
        XCTAssertEqual(spans.strongs.count, 1)
        XCTAssertGreaterThanOrEqual(spans.strongs[0].location, 2, "加粗从正文开始，与标记不重叠")

        // 语法标记里只有 `- ` 与 `**`/`**`，互不覆盖
        let marks = MarkdownStyler.syntaxMarkerRanges(in: text, caretParagraph: nil).all
        XCTAssertEqual(marks.first, NSRange(location: 0, length: 2))
        var cursor = 0
        for range in marks {
            XCTAssertGreaterThanOrEqual(range.location, cursor, "标记区间不得重叠")
            cursor = range.location + range.length
        }
        XCTAssertEqual(marks.count, 3, "`- ` + 两对星号各一条 → 实际 3 条（星号成对合并）")

        // 渲染顺序与真实链路一致：先 applyInline（加粗），再 applyLists（压宽）。
        // 压宽只能碰标记区间，不能把加粗冲掉，也不能把标记撑回原宽。
        let (editor, _) = makeEditor(text)
        guard let storage = editor.textStorage else { return XCTFail("no storage") }
        applyBold(spans, storage)
        applyListMarkers(text, to: editor, caretParagraph: nil)
        editor.layoutSubtreeIfNeeded()

        let boldRange = spans.strongs[0]
        let font = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        guard let font else { return XCTFail("加粗没有生效") }
        XCTAssertTrue(
            NSFontManager.shared.traits(of: font).contains(.boldFontMask),
            "列表项里的 `**加粗**` 仍然是粗体"
        )
        assertMarkerCompressed(editor, line: 0)
        XCTAssertEqual(editor.string, text, "渲染不改正文")
    }

    // MARK: - 渲染链路辅助

    /// 把列表标记压宽 / 还原应用到真的文本视图上，模拟 `Coordinator.applyLists`。
    private func applyListMarkers(_ text: String, to textView: EditorTextView, caretParagraph: NSRange?) {
        guard let storage = textView.textStorage else { return }
        let ns = text as NSString
        let list = MarkdownStyler.listMarkers(in: text)
        storage.beginEditing()
        for marker in list {
            guard marker.markerRange.location + marker.markerRange.length <= ns.length else { continue }
            let para = ns.paragraphRange(for: NSRange(location: marker.markerRange.location, length: 0))
            storage.addAttribute(.paragraphStyle, value: Theme.listParagraph(), range: para)
            let inCaret = ListLayout.isInCaretParagraph(marker, caretParagraph)
            if inCaret {
                storage.removeAttribute(.kern, range: marker.markerRange)
                storage.addAttributes(Theme.visibleMarkerAttributes(), range: marker.markerRange)
            } else {
                let piece = ns.substring(with: marker.markerRange)
                storage.addAttributes(Theme.compressedMarkerAttributes(for: piece), range: marker.markerRange)
            }
        }
        storage.endEditing()
    }

    /// 模拟 `Coordinator.applyInline` 的加粗部分。
    private func applyBold(_ spans: EditorSpans, _ storage: NSTextStorage) {
        for range in spans.strongs {
            guard range.location + range.length <= storage.length else { continue }
            storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
                guard let font = value as? NSFont else { return }
                let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: subRange)
            }
        }
    }

    private func makeEditor(_ text: String) -> (EditorTextView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        let editor = EditorTextView(usingTextLayoutManager: true)
        editor.isRichText = true
        editor.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 28, height: 24)
        scrollView.documentView = editor
        window.contentView = scrollView
        editor.string = text
        editor.layoutSubtreeIfNeeded()
        return (editor, window)
    }

    private func textViewTextStart(_ editor: EditorTextView, line: Int) -> CGFloat? {
        textStartX(editor, line: line)
    }
}

/// 只做一件事：给测试的文本视图一个独立的撤销栈。
private final class UndoDelegate: NSObject, NSTextViewDelegate {
    let manager: UndoManager
    init(manager: UndoManager) { self.manager = manager }
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}
