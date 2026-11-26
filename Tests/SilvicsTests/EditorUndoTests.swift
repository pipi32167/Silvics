import AppKit
import XCTest
@testable import Silvics

/// issue #35：⌘Z 会错误回退、删掉整篇。
///
/// 三条根因各有一组用例：
/// 1. 整场输入合成一步 → 一次 ⌘Z 清空整篇（`UndoPolicy` + 集成用例）。
/// 2. 撤销栈是窗口级的，换笔记不换栈 → 退到上一篇的内容（隔离用例）。
/// 3. 外部整体替换正文后旧动作还在 → 删错位置（外部替换用例）。
final class EditorUndoTests: XCTestCase {

    // MARK: - 工具

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
        textView.isEditable = true
        textView.isSelectable = true
        // 与 `makeNSView` 一致：撤销由 Coordinator 自管。
        textView.allowsUndo = false
        textView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        window.contentView = scrollView
        textView.string = text
        return (textView, window)
    }

    /// 造一个真的 Coordinator（跟 `makeNSView` 走同一套接线），返回文本视图。
    @discardableResult
    private func makeEditor(
        _ text: String,
        published: ((String) -> Void)? = nil
    ) -> (EditorTextView, NSWindow, NoteEditorView.Coordinator) {
        let (textView, window) = makeTextView(text)
        let parent = NoteEditorView(
            initialText: text,
            text: text,
            resolvedKeys: [],
            mentions: [],
            appearance: AppearanceSettings(),
            editable: true,
            rendersWikiLinks: true,
            onChange: { published?($0) },
            completionProvider: { _, _ in [] },
            onCreateNote: { _ in nil },
            onOpenLink: { _ in }
        )
        let coordinator = parent.makeCoordinator()
        coordinator.wire(textView: textView)
        coordinator.attach(textView: textView, scrollView: window.contentView as! NSScrollView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        return (textView, window, coordinator)
    }

    private func type(_ text: String, into textView: NSTextView) {
        for ch in text {
            textView.insertText(String(ch), replacementRange: textView.selectedRange())
        }
    }

    /// 走菜单那条路：`undo:` 沿响应链落到 `EditorTextView`。
    @discardableResult
    private func pressUndo(_ textView: EditorTextView) -> Bool {
        NSApp.sendAction(#selector(EditorTextView.undo(_:)), to: textView, from: nil)
    }

    @discardableResult
    private func pressRedo(_ textView: EditorTextView) -> Bool {
        NSApp.sendAction(#selector(EditorTextView.redo(_:)), to: textView, from: nil)
    }

    // MARK: - 根因 1：一次撤销不该退掉整篇

    func testUndoStopsAtSentenceBoundary() {
        let (textView, _, _) = makeEditor("开头\n")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("甲乙丙。丁戊", into: textView)

        pressUndo(textView)
        XCTAssertEqual(textView.string, "开头\n甲乙丙。", "一次撤销只退回上一个句读之后")

        pressUndo(textView)
        XCTAssertEqual(textView.string, "开头\n", "再撤一次才回到句子开头")
    }

    func testUndoKeepsFirstParagraphWhenTypingManyCharacters() {
        let (textView, _, _) = makeEditor("原本的正文")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        // 超过 `UndoPolicy.maxCharactersPerStep`，必须自动切成多步。
        type(String(repeating: "字", count: UndoPolicy.maxCharactersPerStep * 3), into: textView)

        pressUndo(textView)
        let afterFirst = (textView.string as NSString).length
        XCTAssertEqual(afterFirst, ("原本的正文" as NSString).length + UndoPolicy.maxCharactersPerStep * 2,
                       "一步最多退 \(UndoPolicy.maxCharactersPerStep) 个字，不能整篇一起退")

        for _ in 0..<2 { pressUndo(textView) }
        XCTAssertEqual(textView.string, "原本的正文", "三步撤完才回到原文")
    }

    func testIdleCommitSplitsLongRunWithoutPunctuation() {
        let (textView, window, _) = makeEditor("正文")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("甲乙", into: textView)

        // 停笔超过空闲间隔：本次操作收尾。
        let waited = expectation(description: "空闲收步")
        DispatchQueue.main.asyncAfter(deadline: .now() + UndoPolicy.idleInterval + 0.4) { waited.fulfill() }
        wait(for: [waited], timeout: UndoPolicy.idleInterval + 3)

        type("丙丁", into: textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        pressUndo(textView)
        XCTAssertEqual(textView.string, "正文甲乙", "停笔后的字单独一步，不跟前面的并在一起")
    }

    func testBoundaryLooksAtInsertedTextNotDocumentTail() {
        let (textView, _, _) = makeEditor("甲乙\n")
        // 在开头插入，正文末尾没有标点；断步要看「插入的字」，不是「正文末尾的字」。
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("丙。", into: textView)
        type("丁戊", into: textView)
        XCTAssertEqual(textView.string, "丙。丁戊甲乙\n")

        pressUndo(textView)
        XCTAssertEqual(textView.string, "丙。甲乙\n", "只退「丁戊」，不退「丙。」")
    }

    func testUndoRestoresCaretBeforeTheStep() {
        let (textView, _, _) = makeEditor("甲乙\n")
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        type("丙", into: textView)
        XCTAssertEqual(textView.selectedRange().location, 2)

        pressUndo(textView)
        XCTAssertEqual(textView.string, "甲乙\n")
        XCTAssertEqual(textView.selectedRange().location, 1, "撤销后光标回到改动前的位置")
    }

    // MARK: - 根因 2：换笔记不能退到上一篇

    func testUndoInAnotherNoteLeavesItUntouched() {
        let (viewA, window, _) = makeEditor("第一篇")
        viewA.setSelectedRange(NSRange(location: (viewA.string as NSString).length, length: 0))
        type("改了", into: viewA)

        // 换笔记：新视图、新撤销栈，同一个窗口。
        let (viewB, _, _) = makeEditor("第二篇")
        XCTAssertTrue(window.makeFirstResponder(viewB))
        let before = viewB.string

        pressUndo(viewB)
        XCTAssertEqual(viewB.string, before, "第二篇不能被第一篇的撤销动作改到")
        XCTAssertFalse(viewB.canUndoAction?() ?? true, "新笔记一开始没有可撤销的操作")
    }

    // MARK: - 根因 3：外部整体替换后旧快照失效

    func testExternalReplaceClearsUndoStack() {
        let (textView, _, coordinator) = makeEditor("原文")
        _ = coordinator
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("新加的字", into: textView)
        XCTAssertTrue(textView.canUndoAction?() ?? false)

        coordinator.applyExternalText("改名后的正文", to: textView)
        XCTAssertEqual(textView.string, "改名后的正文")
        XCTAssertFalse(textView.canUndoAction?() ?? true, "外部替换后不再给旧的撤销动作")
        pressUndo(textView)
        XCTAssertEqual(textView.string, "改名后的正文", "按 ⌘Z 不能改动正文")
    }

    // MARK: - 重做

    func testRedoRestoresUndoneTyping() {
        let (textView, _, _) = makeEditor("开头")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("甲乙丙", into: textView)

        pressUndo(textView)
        XCTAssertEqual(textView.string, "开头")
        XCTAssertTrue(textView.canRedoAction?() ?? false, "撤销后要能重做")

        pressRedo(textView)
        XCTAssertEqual(textView.string, "开头甲乙丙")
        XCTAssertFalse(textView.canRedoAction?() ?? true)
    }

    func testNewTypingClearsRedo() {
        let (textView, _, _) = makeEditor("开头")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("甲", into: textView)
        pressUndo(textView)

        type("乙", into: textView)
        XCTAssertFalse(textView.canRedoAction?() ?? true, "重新打字后重做栈作废")
    }

    // MARK: - 一次操作 = 一步

    func testTodoToggleIsOneUndoStep() {
        let (textView, _, _) = makeEditor("- [ ] 甲\n- [ ] 乙")
        XCTAssertTrue(textView.toggleTodo(at: 0))
        XCTAssertEqual(textView.string, "- [x] 甲\n- [ ] 乙")

        pressUndo(textView)
        XCTAssertEqual(textView.string, "- [ ] 甲\n- [ ] 乙", "勾选要能一步退回")
    }

    func testUndoReportsPublishedBody() {
        var published: [String] = []
        let (textView, _, _) = makeEditor("正文", published: { published.append($0) })
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        type("加字", into: textView)
        published.removeAll()

        pressUndo(textView)
        XCTAssertEqual(published.last, "正文", "撤销后要回报正文，否则库里留下被撤销的内容")
    }
}

/// `UndoPolicy` 的边界值。
final class UndoPolicyTests: XCTestCase {

    func testBoundaryCharactersBreakStep() {
        for tail in ["。", "，", "、", "；", "：", "！", "？", "\n", " ", ".", ",", "!", "?", "）", "】"] {
            XCTAssertTrue(UndoPolicy.endsAtBoundary(tail), "\(tail) 之后应该断开一步")
        }
    }

    func testRegularCharactersDoNotBreakStep() {
        for tail in ["甲", "a", "Z", "9", "”"] {
            XCTAssertFalse(UndoPolicy.endsAtBoundary(tail), "\(tail) 不该断开一步")
        }
    }

    func testMaxCharactersBreakStep() {
        XCTAssertFalse(UndoPolicy.shouldBreak(tail: "字", charactersSinceBreak: UndoPolicy.maxCharactersPerStep - 1))
        XCTAssertTrue(UndoPolicy.shouldBreak(tail: "字", charactersSinceBreak: UndoPolicy.maxCharactersPerStep))
    }

    func testDeletionCountsTowardStepSize() {
        // 删除没有插入尾巴，靠累计字数断开。
        XCTAssertTrue(UndoPolicy.shouldBreak(tail: "", charactersSinceBreak: UndoPolicy.maxCharactersPerStep))
        XCTAssertFalse(UndoPolicy.shouldBreak(tail: "", charactersSinceBreak: 1))
    }

    func testEmptyTailDoesNotBreakEarly() {
        XCTAssertFalse(UndoPolicy.shouldBreak(tail: "", charactersSinceBreak: 0))
    }
}

/// 撤销栈的纯逻辑。
final class EditorUndoStackTests: XCTestCase {

    private func step(_ before: String, _ after: String, name: String = "打字") -> EditorUndoStep {
        EditorUndoStep(before: before, after: after, caretBefore: 0, caretAfter: 0, name: name)
    }

    func testTakeUndoMovesStepToRedo() {
        var stack = EditorUndoStack()
        stack.record(step("", "甲"))
        XCTAssertTrue(stack.canUndo)
        XCTAssertFalse(stack.canRedo)

        let undone = stack.takeUndo()
        XCTAssertEqual(undone?.before, "")
        XCTAssertFalse(stack.canUndo)
        XCTAssertTrue(stack.canRedo)

        let redone = stack.takeRedo()
        XCTAssertEqual(redone?.after, "甲")
        XCTAssertTrue(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
    }

    func testEmptyStepIsIgnored() {
        var stack = EditorUndoStack()
        stack.record(step("一样", "一样"))
        XCTAssertFalse(stack.canUndo)
    }

    func testRecordClearsRedo() {
        var stack = EditorUndoStack()
        stack.record(step("", "甲"))
        _ = stack.takeUndo()
        XCTAssertTrue(stack.canRedo)

        stack.record(step("", "乙"))
        XCTAssertFalse(stack.canRedo, "分叉后重做栈作废")
        XCTAssertEqual(stack.undoCount, 1)
    }

    func testLimitDropsOldestStep() {
        var stack = EditorUndoStack(limit: 2)
        stack.record(step("0", "1"))
        stack.record(step("1", "2"))
        stack.record(step("2", "3"))
        XCTAssertEqual(stack.undoCount, 2)

        XCTAssertEqual(stack.takeUndo()?.after, "3")
        XCTAssertEqual(stack.takeUndo()?.after, "2")
        XCTAssertNil(stack.takeUndo(), "最旧的一步按上限丢掉了")
    }

    func testRemoveAllClearsBothStacks() {
        var stack = EditorUndoStack()
        stack.record(step("", "甲"))
        _ = stack.takeUndo()
        stack.removeAll()
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
    }
}
