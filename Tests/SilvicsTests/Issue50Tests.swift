import AppKit
import XCTest
@testable import Silvics

/// issue #50「体验优化 20261127」的四条编辑器侧改动：
///
/// 1. 回车续行：待办 / 无序 / 有序列表在回车后自动写下一项。
/// 2. 前置空白：列表、待办、引用的正文与标题同左缘（不再固定右移 22pt）。
/// 3. 多级缩进：按缩进算层级，第 2 / 3 级各右移 18pt，符号换形状。
/// 4. 长文切换：一次逐行扫描 + 样式计划缓存，不再对整篇扫五遍。
///
/// 几何在真 `NSTextView`（TextKit 2）上量，正文一个字符都不许改。
final class Issue50Tests: XCTestCase {

    // MARK: - 工具

    private func makeEditor(
        _ text: String,
        caretLine: Int? = 0
    ) -> (EditorTextView, NSWindow, NoteEditorView.Coordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.frame = NSRect(x: 0, y: 0, width: 460, height: 360)
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
        // `NSTextView.string =` 会把光标放到文末；不显式指定，最后一段就成了「光标段落」，
        // 那一段按源码显示，宽度连同前缀一起量。
        if let caretLine {
            textView.setSelectedRange(NSRange(location: paragraphStart(text, line: caretLine), length: 0))
        }
        coordinator.restyle(force: true)
        textView.layoutSubtreeIfNeeded()
        return (textView, window, coordinator)
    }

    private func paragraphStart(_ text: String, line: Int) -> Int {
        let ns = text as NSString
        var offset = 0
        for _ in 0..<line {
            let found = ns.range(of: "\n", range: NSRange(location: offset, length: ns.length - offset))
            guard found.location != NSNotFound else { return offset }
            offset = found.location + 1
        }
        return offset
    }

    /// 把光标放到第 `line` 行的末尾（续行只能从行内触发）。
    private func caretToLineEnd(_ textView: EditorTextView, line: Int) {
        let ns = textView.string as NSString
        let start = paragraphStart(textView.string, line: line)
        var end = ns.length
        let found = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
        if found.location != NSNotFound { end = found.location }
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.didChangeText()
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

    /// 正文（跳过整段标记）在视图坐标里的 x。
    private func bodyStartX(_ textView: EditorTextView, line: Int) -> CGFloat? {
        let text = textView.string
        let start = paragraphStart(text, line: line)
        let prefix = MarkdownStyler.listMarkers(in: text)
            .first { $0.markerRange.location == start }?
            .markerRange.length ?? 0
        return characterX(textView, at: start + prefix)
    }

    // MARK: - 回车续行

    func testNewlineContinuesUnorderedList() {
        let text = "- 第一项"
        let (editor, _, _) = makeEditor(text)
        caretToLineEnd(editor, line: 0)
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "- 第一项\n- ", "回车后自动写下一个项目符号")
        XCTAssertEqual(editor.selectedRange().location, (editor.string as NSString).length, "光标落在新项后面")
    }

    func testNewlineContinuesOrderedListAndBumpsNumber() {
        let text = "1. 第一项"
        let (editor, _, _) = makeEditor(text)
        caretToLineEnd(editor, line: 0)
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "1. 第一项\n2. ", "有序列表序号 +1，不重排原文")
    }

    func testNewlineKeepsOrderedDelimiterStyle() {
        let text = "3) 甲"
        let (editor, _, _) = makeEditor(text)
        caretToLineEnd(editor, line: 0)
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "3) 甲\n4) ", "`)` 分隔符照搬，不改写成 `.`")
    }

    func testNewlineContinuesTodoAsUnchecked() {
        let text = "- [x] 已完成的一项"
        let (editor, _, _) = makeEditor(text)
        caretToLineEnd(editor, line: 0)
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "- [x] 已完成的一项\n- [ ] ", "新待办一律未勾选")
    }

    func testNewlineKeepsNestedIndent() {
        let text = "- 一级\n  - 二级"
        let (editor, _, _) = makeEditor(text)
        caretToLineEnd(editor, line: 1)
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "- 一级\n  - 二级\n  - ", "缩进照搬，多级列表能一直写下去")
    }

    func testNewlineOnEmptyItemExitsList() {
        let text = "- 第一项\n- "
        let (editor, _, _) = makeEditor(text)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "- 第一项\n", "空条目回车等于退出列表，只留下空行")
        XCTAssertEqual(editor.selectedRange().location, 6, "光标停在原来的空行上")
    }

    func testNewlineInsideCodeBlockDoesNotContinueList() {
        let text = "```\n- 代码里的减号\n```"
        let (editor, _, _) = makeEditor(text)
        caretToLineEnd(editor, line: 1)
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "```\n- 代码里的减号\n\n```", "围栏里的 `- ` 不是列表，回车只换行")
    }

    func testNewlineOnPlainParagraphIsPlainNewline() {
        let text = "普通段落"
        let (editor, _, _) = makeEditor(text)
        caretToLineEnd(editor, line: 0)
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "普通段落\n", "没有前缀就只是换行")
    }

    // MARK: - 前置空白：正文与标题同左缘

    func testFirstLevelListBodyAlignsWithParagraph() {
        let text = "正文段落\n- 列表项"
        let (editor, _, _) = makeEditor(text)
        editor.layoutSubtreeIfNeeded()
        let plain = characterX(editor, at: 0) ?? -1
        let listBody = bodyStartX(editor, line: 1) ?? -2
        XCTAssertGreaterThan(plain, 0, "量得到普通段落的位置")
        XCTAssertEqual(listBody, plain, accuracy: 0.5,
                       "第 1 级列表正文与普通段落同左缘（issue #50 的前置空白）")
    }

    func testFirstLevelTodoAndQuoteAlignWithParagraph() {
        let text = "正文段落\n- [ ] 待办\n> 引用\n收尾"
        let (editor, _, _) = makeEditor(text, caretLine: 3)
        editor.layoutSubtreeIfNeeded()
        let plain = characterX(editor, at: 0) ?? -1
        // 待办正文：跳过整段 `- [ ] ` 前缀。
        let todoBody = bodyStartX(editor, line: 1) ?? -2
        XCTAssertEqual(todoBody, plain, accuracy: 0.5, "第 1 级待办正文与普通段落同左缘")

        let quoteStart = paragraphStart(text, line: 2)
        let quoteBody = characterX(editor, at: quoteStart + 2) ?? -2
        XCTAssertEqual(quoteBody, plain, accuracy: 0.5, "第 1 级引用正文与普通段落同左缘")
    }

    func testListIndentIsZeroAndStepsByLevel() {
        XCTAssertEqual(ListLayout.offset(level: 1), 0, "第 1 级不留额外缩进")
        XCTAssertEqual(ListLayout.offset(level: 2), ListLayout.levelStep)
        XCTAssertEqual(ListLayout.offset(level: 3), ListLayout.levelStep * 2)
        XCTAssertEqual(ListLayout.offset(level: 9), ListLayout.levelStep * 2, "超过上限按第 3 级排")
    }

    // MARK: - 多级缩进

    func testLevelParsedFromIndent() {
        XCTAssertEqual(ListLayout.level(forIndent: ""), 1)
        XCTAssertEqual(ListLayout.level(forIndent: "  "), 2, "2 个空格算一级")
        XCTAssertEqual(ListLayout.level(forIndent: "\t"), 2, "1 个 tab 算一级")
        XCTAssertEqual(ListLayout.level(forIndent: "    "), 3)
        XCTAssertEqual(ListLayout.level(forIndent: "      "), 3, "再深也按第 3 级排")

        let text = "- 一级\n  - 二级\n    - 三级"
        let levels = MarkdownStyler.listMarkers(in: text).map(\.level)
        XCTAssertEqual(levels, [1, 2, 3])
    }

    func testNestedListIsIndentedPerLevel() {
        let text = "- 一级\n  - 二级\n    - 三级\n收尾"
        let (editor, _, _) = makeEditor(text, caretLine: 3)
        editor.layoutSubtreeIfNeeded()
        let first = bodyStartX(editor, line: 0) ?? -1
        let second = bodyStartX(editor, line: 1) ?? -2
        let third = bodyStartX(editor, line: 2) ?? -3
        XCTAssertEqual(second - first, ListLayout.levelStep, accuracy: 0.5, "第 2 级比第 1 级右移一格")
        XCTAssertEqual(third - second, ListLayout.levelStep, accuracy: 0.5, "第 3 级再右移一格")
        XCTAssertEqual(editor.string, text, "层级别只改属性，正文一个字符不动")
    }

    func testNestedQuoteIsIndentedPerLevel() {
        let text = "> 一级引用\n  > 二级引用\n收尾"
        let marks = MarkdownStyler.quoteMarks(in: text)
        XCTAssertEqual(marks.map(\.level), [1, 2])
        XCTAssertEqual((text as NSString).substring(with: marks[1].range), "  > ", "引用区间含缩进")

        let (editor, _, _) = makeEditor(text, caretLine: 2)
        let firstStart = paragraphStart(text, line: 0)
        let secondStart = paragraphStart(text, line: 1)
        let first = characterX(editor, at: firstStart + 2) ?? -1
        let second = characterX(editor, at: secondStart + 4) ?? -2
        XCTAssertEqual(second - first, ListLayout.levelStep, accuracy: 0.5, "二级引用右移一格")
    }

    // MARK: - 待办复选框

    func testCheckboxIsBiggerAndHangsInGutter() {
        let text = "- [ ] 甲"
        let (editor, _, _) = makeEditor(text)
        editor.listMarkers = MarkdownStyler.listMarkers(in: text)
        editor.caretParagraph = nil
        editor.layoutSubtreeIfNeeded()

        guard let box = editor.todoCheckboxFrames.first else {
            return XCTFail("没有复选框")
        }
        XCTAssertEqual(box.width, ListLayout.checkboxSize, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(ListLayout.checkboxSize, 17, "复选框比原来（14）大一号")

        let textStart = bodyStartX(editor, line: 0) ?? -1
        XCTAssertLessThan(box.maxX, textStart, "复选框要挂在正文左侧，不能压住文字")
        XCTAssertGreaterThan(textStart - box.maxX, 1, "方框与正文之间要留出间隔")
    }

    // MARK: - AI 气泡：紧凑排版 + 高度跟着正文

    func testCompactEditorMeasuresHeightByContent() {
        let short = "一行"
        let long = "第一行\n第二行\n第三行"
        let (shortView, _, shortCoordinator) = makeEditor(short)
        let (longView, _, longCoordinator) = makeEditor(long)

        let shortHeight = shortCoordinator.measuredHeight(of: shortView, width: 200)
        let longHeight = longCoordinator.measuredHeight(of: longView, width: 200)
        XCTAssertGreaterThan(shortHeight, 0, "量得到高度")
        XCTAssertGreaterThan(longHeight, shortHeight * 2, "三行比一行高，气泡高度跟着正文走（\(shortHeight) → \(longHeight)）")
    }

    // MARK: - 长文：一次扫描 + 样式计划缓存

    func testLineScanReturnsAllViewsInOnePass() {
        let text = """
        ## 标题
        - 无序
          - 嵌套
        - [ ] 待办
        > 引用
        ```
        - 围栏内不算列表
        ```
        """
        let scan = MarkdownStyler.scan(text)
        XCTAssertEqual(scan.listMarkers.map(\.level), [1, 2, 1], "围栏里的行不算列表")
        XCTAssertEqual(scan.quotes.count, 1)
        XCTAssertEqual(scan.headings.count, 1)
        XCTAssertEqual(scan.todos.count, 1)
        XCTAssertEqual(scan.fences.count, 2)
        XCTAssertEqual(scan.indents.count, 1, "只有缩进过的标记行才有缩进区间（这里只有「  - 嵌套」）")
    }

    func testStylePlanIsCachedPerText() {
        EditorStylePlan.reset()
        let text = "# 甲\n- 乙\n- [ ] 丙"
        let first = EditorStylePlan.plan(for: text)
        XCTAssertFalse(first.fromCache, "第一次必然现算")
        let second = EditorStylePlan.plan(for: text)
        XCTAssertTrue(second.fromCache, "同一篇正文第二次走缓存")
        XCTAssertEqual(second.scan.listMarkers, first.scan.listMarkers, "缓存不改结果")

        let other = EditorStylePlan.plan(for: text + "\n- 丁")
        XCTAssertFalse(other.fromCache, "正文变了要重算")
        XCTAssertEqual(other.scan.listMarkers.count, 3)
    }

    /// 长文冷启动与热重排的耗时。Debug 构建的数字只用来盯回归，不是用户可见值。
    func testLongDocumentRestyleStaysWithinBudget() {
        let body = (0..<600).map { index -> String in
            switch index % 5 {
            case 0: return "## 第 \(index) 节"
            case 1: return "- 列表 \(index)：一段中等长度的中文说明，用来撑出行数。"
            case 2: return "- [ ] 待办 \(index)：把这件事做完。"
            case 3: return "> 引用 \(index)：引用里也有一段话。"
            default: return "正文段落 \(index)：The quick brown fox jumps over the lazy dog."
            }
        }.joined(separator: "\n\n")

        let (editor, _, coordinator) = makeEditor(body)
        // `makeEditor` 已经排过一次；清掉计划缓存，下面量的才是真正的冷启动。
        EditorStylePlan.reset()

        let coldStart = CFAbsoluteTimeGetCurrent()
        coordinator.restyle(force: true)
        let cold = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000

        let warmStart = CFAbsoluteTimeGetCurrent()
        coordinator.restyle(force: true)
        let warm = (CFAbsoluteTimeGetCurrent() - warmStart) * 1000

        XCTAssertGreaterThan(editor.string.count, 8_000, "样本要够长，量出来的数才有意义")
        XCTAssertLessThan(warm, cold, "命中样式缓存应当更快（冷 \(cold) ms / 热 \(warm) ms）")
        // Debug 构建的上限。Release 实测约为它的 1/2。
        XCTAssertLessThan(cold, 600, "长文冷启动重排超预算：\(cold) ms")
        XCTAssertLessThan(warm, 300, "长文热重排超预算：\(warm) ms")
    }
}
