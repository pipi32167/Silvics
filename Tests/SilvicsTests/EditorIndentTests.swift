import AppKit
import XCTest
@testable import Silvics

/// issue #41：行首空白在编辑态也要消失。
///
/// 现象：光标停在 `  - 甲` 这一行时，整行按源码显示，行首两个空格照样占宽，
/// 正文比其他列表行右移 8 pt；光标移开又缩回去。标题 / 有序 / 待办 / 引用同理。
///
/// 结论：**行首缩进在编辑器里永远不占宽**（不是「只占光标段落」），
/// 光标段落只恢复语法标记本身（`- `、`1. `、`- [ ] `、`> `、`## `）的宽度。
///
/// 几何靠真 `NSTextView`（TextKit 2）量，不看属性表猜；正文一个字符都不许改。
final class EditorIndentTests: XCTestCase {

    // MARK: - 工具

    /// 造一个真的 `Coordinator`（与 `makeNSView` 同一套接线），可指定光标段落。
    private func makeEditor(
        _ text: String,
        caretLine: Int? = nil
    ) -> (EditorTextView, NSWindow, NoteEditorView.Coordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
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
        if let caretLine {
            textView.setSelectedRange(NSRange(location: paragraphStart(text, line: caretLine), length: 0))
        }
        coordinator.restyle(force: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.layoutSubtreeIfNeeded()
        return (textView, window, coordinator)
    }

    private func paragraphStart(_ text: String, line: Int) -> Int {
        let ns = text as NSString
        var offset = 0
        for _ in 0..<line {
            let newline = ns.range(of: "\n", range: NSRange(location: offset, length: ns.length - offset))
            guard newline.location != NSNotFound else { break }
            offset = newline.location + 1
        }
        return offset
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

    /// 该行正文（跳过行首整段前缀）在视图坐标里的 x。
    private func bodyStartX(_ textView: EditorTextView, line: Int) -> CGFloat? {
        let text = textView.string
        let start = paragraphStart(text, line: line)
        let prefix = MarkdownStyler.listMarkers(in: text)
            .first { $0.markerRange.location == start }?
            .markerRange.length ?? 0
        return characterX(textView, at: start + prefix)
    }

    /// 列表正文的理论左缘：容器左缘 + 行片段留白 + 列表缩进 + 可见标记宽度。
    private func expectedBodyStart(
        _ textView: EditorTextView,
        visiblePrefix: String
    ) -> CGFloat {
        textView.textContainerOrigin.x + 5 + ListLayout.indent + Theme.visibleMarkerWidth(visiblePrefix)
    }

    private func assertClose(
        _ got: CGFloat?,
        _ expected: CGFloat,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let got else { return XCTFail("量不到位置：\(message)", file: file, line: line) }
        XCTAssertEqual(got, expected, accuracy: 1, "\(message)（实际 \(got)，期望 \(expected)）", file: file, line: line)
    }

    // MARK: - S49 无序列表：光标段落不吃缩进

    func testS49IndentedUnorderedDropsIndentInCaretParagraph() {
        let text = "- 顶层\n  - 缩进两格"
        let (textView, _, _) = makeEditor(text, caretLine: 1)

        assertClose(bodyStartX(textView, line: 1), expectedBodyStart(textView, visiblePrefix: "- "),
                   "光标在缩进行，正文只让出 `- ` 的宽度，行首两个空格不占宽")

        // 对照：整段前缀（含缩进）都露出来时会更靠右，证明上面不是恒真
        let raw = textView.textContainerOrigin.x + 5 + ListLayout.indent
            + Theme.visibleMarkerWidth("  - ")
        XCTAssertGreaterThan(raw, expectedBodyStart(textView, visiblePrefix: "- "), "对照值要比期望值大")
        XCTAssertGreaterThan(abs((bodyStartX(textView, line: 1) ?? 0) - raw), 5,
                             "实际位置不能等于「缩进也占宽」的位置")

        XCTAssertEqual(textView.string, text, "渲染不改正文")
        XCTAssertTrue(textView.string.hasSuffix("  - 缩进两格"), "缩进字符一个不许少")
    }

    // MARK: - S50 有序 / 待办：同一套规则

    func testS50IndentedOrderedAndTodoDropIndentInCaretParagraph() {
        for (text, line, mark) in [
            ("1. 顶层\n  1. 缩进两格", 1, "1. "),
            ("1. 顶层\n  10. 缩进两格", 1, "10. "),
            ("- [ ] 顶层\n  - [ ] 缩进两格", 1, "- [ ] "),
            ("- [x] 顶层\n  - [x] 缩进两格", 1, "- [x] "),
        ] {
            let (textView, _, _) = makeEditor(text, caretLine: line)
            assertClose(bodyStartX(textView, line: line), expectedBodyStart(textView, visiblePrefix: mark),
                       "「\(text.components(separatedBy: "\n")[line])」行首缩进不占宽")
        }
    }

    // MARK: - S51 tab 缩进：一个字符，不是一个 4 字符

    func testS51TabIndentCountsOneCharacter() {
        let text = "- 顶层\n\t- 缩进一个 tab"
        let marker = MarkdownStyler.listMarkers(in: text).last
        XCTAssertEqual(marker?.indent, 4, "缩进量按 tab = 4 记")
        let secondLineStart = paragraphStart(text, line: 1)
        XCTAssertEqual(marker?.visibleRange, NSRange(location: secondLineStart + 1, length: 2),
                       "语法标记从项目符号开始：tab 只是一个字符，不是四个")
        XCTAssertEqual((text as NSString).substring(with: marker!.visibleRange), "- ")

        let (textView, _, _) = makeEditor(text, caretLine: 1)
        assertClose(bodyStartX(textView, line: 1), expectedBodyStart(textView, visiblePrefix: "- "),
                   "tab 缩进同样不占宽")
    }

    // MARK: - S52 引用：缩进同样藏起来

    func testS52IndentedQuoteHidesIndent() {
        let text = "> 顶层引用\n  > 缩进引用"
        let (textView, _, _) = makeEditor(text, caretLine: 1)
        let lineStart = paragraphStart(text, line: 1)

        // 引用段落本身有 22pt 缩进（`Theme.quoteParagraph`），缩进在这里是「行首额外空格」。
        // 光标在引用行：`>` 落在引用缩进处（行首两个空格不占宽），正文让出 `> ` 的宽度。
        let quoteIndent = textView.textContainerOrigin.x + 5 + ListLayout.indent
        assertClose(characterX(textView, at: lineStart + 2), quoteIndent,
                   "`>` 应落在引用缩进处，行首两个空格不占宽")
        assertClose(characterX(textView, at: lineStart + 4),
                   quoteIndent + Theme.visibleMarkerWidth("> "),
                   "正文让出 `> ` 的宽度")

        XCTAssertEqual(textView.string, text)
    }

    // MARK: - S53 标题：≤3 个前导空格仍算标题，且前导空格不占宽

    func testS53IndentedHeadingIsHeadingAndHidesIndent() {
        let heading = "  ## 缩进标题"
        XCTAssertEqual(MarkdownStyler.headingMarkerRanges(in: heading), [NSRange(location: 2, length: 3)],
                       "前缀区间从 `#` 开始，不含前导空格")
        XCTAssertEqual(MarkdownStyler.lineIndentRanges(in: heading), [NSRange(location: 0, length: 2)],
                       "前导空格单独作为「缩进」区间，交给永不占宽那一组")

        // 4 个空格是缩进代码块，不是标题（CommonMark）
        XCTAssertTrue(MarkdownStyler.headingMarkerRanges(in: "    ## 甲").isEmpty)

        let text = "正文\n  ## 缩进标题"
        let (textView, _, _) = makeEditor(text, caretLine: 1)
        assertClose(characterX(textView, at: paragraphStart(text, line: 1) + 2),
                   textView.textContainerOrigin.x + 5,
                   "光标在标题行：`#` 从容器左缘开始，前导空格不占宽")
        XCTAssertEqual(textView.string, text)
    }

    // MARK: - S54 渲染态（光标不在这一段）不受影响

    func testS54RenderedLinesStayAlignedWhateverTheIndent() {
        let text = "- 零个缩进\n  - 两个空格\n\t- 一个 tab\n    - 四个空格\n收尾"
        let (textView, _, _) = makeEditor(text, caretLine: 4)
        let expected = textView.textContainerOrigin.x + 5 + ListLayout.indent
        for line in 0...3 {
            assertClose(bodyStartX(textView, line: line), expected,
                       "第 \(line) 行渲染态的正文左缘都落在缩进处")
        }
    }

    // MARK: - 纯函数：哪些行有「行首缩进」

    func testLineIndentRangesCoverAllMarkerKinds() {
        let text = """
        ## 标题
          ## 缩进标题
        - 无序
          - 缩进无序
        1. 有序
          1. 缩进有序
        - [ ] 待办
          - [ ] 缩进待办
        > 引用
          > 缩进引用
        普通段落
          普通段落，前面有空格但不是标记
        """
        let indentRanges = MarkdownStyler.lineIndentRanges(in: text)
        let ns = text as NSString
        let plain = indentRanges.map { ns.substring(with: $0) }
        XCTAssertEqual(plain, ["  ", "  ", "  ", "  ", "  "],
                       "每一条标记行各一条缩进区间；普通段落前面的空格不算")
        // 区间按位置升序、互不重叠
        var cursor = 0
        for range in indentRanges {
            XCTAssertGreaterThanOrEqual(range.location, cursor)
            cursor = range.location + range.length
        }
    }
}
