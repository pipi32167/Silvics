import AppKit
import XCTest
@testable import Silvics

/// 编辑器体验优化（issue #8）三条：
/// - 输入 `[` 自动补 `]`
/// - 按住 ⌘ 指针在引用上变成手型
/// - 标题前缀（`## `）压到 0 宽，标题正文不再被顶出缩进
final class EditorUXTests: XCTestCase {

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
        textView.allowsUndo = true
        textView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 28, height: 24)
        scrollView.documentView = textView
        window.contentView = scrollView
        textView.string = text
        textView.layoutSubtreeIfNeeded()
        return (textView, window)
    }

    private func type(_ text: String, into textView: EditorTextView) {
        textView.insertText(text, replacementRange: textView.selectedRange())
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

    private func paragraph(_ text: String, line: Int) -> NSRange {
        let ns = text as NSString
        var start = 0
        for _ in 0..<line {
            let newline = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            guard newline.location != NSNotFound else { break }
            start = newline.location + 1
        }
        return ns.paragraphRange(for: NSRange(location: start, length: 0))
    }

    // MARK: - 1. 输入 `[` 自动补 `]`

    func testBracketAutoClosesAndCaretStaysInside() {
        let (textView, _) = makeTextView("")
        type("[", into: textView)
        XCTAssertEqual(textView.string, "[]")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0), "光标应停在括号中间")
    }

    func testSecondBracketNestsAndKeepsWikiLinkTypable() {
        let (textView, _) = makeTextView("")
        type("[", into: textView)
        type("[", into: textView)
        XCTAssertEqual(textView.string, "[[]]")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))

        type("笔记", into: textView)
        XCTAssertEqual(textView.string, "[[笔记]]")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
    }

    func testClosingBracketSkipsTheAutoInsertedOne() {
        let (textView, _) = makeTextView("")
        type("[", into: textView)
        type("甲", into: textView)
        // 光标后面是自动补的 `]`：再打 `]` 应该跨过去，而不是插成 `]甲]]`
        type("]", into: textView)
        XCTAssertEqual(textView.string, "[甲]")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))

        // 跨过之后再打 `]` 才是真的插字符
        type("]", into: textView)
        XCTAssertEqual(textView.string, "[甲]]")
    }

    func testBracketWrapsSelectionWhenThereIsOne() {
        let (textView, _) = makeTextView("甲乙丙")
        textView.setSelectedRange(NSRange(location: 1, length: 1))
        type("[", into: textView)
        XCTAssertEqual(textView.string, "甲[乙]丙")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 1), "选中的字要留在括号里")
    }

    func testBracketAutoCloseIsUndoable() {
        let (textView, _) = makeTextView("")
        textView.undoManager?.removeAllActions()
        type("[", into: textView)
        XCTAssertEqual(textView.string, "[]")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "", "自动补的 `]` 必须一次撤销干净")
    }

    func testBackspaceRemovesBothBrackets() {
        let (textView, _) = makeTextView("")
        type("[", into: textView)
        XCTAssertEqual(textView.string, "[]")
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.string, "", "光标在 `[]` 中间退格应两个一起删，不留孤立的 `]`")
    }

    func testBackspaceKeepsUnpairedBracket() {
        let (textView, _) = makeTextView("")
        type("[", into: textView)
        type("甲", into: textView)      // [甲]
        textView.deleteBackward(nil)     // [ ]
        XCTAssertEqual(textView.string, "[]")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.deleteBackward(nil)     // 光标在 `]` 之后：普通退格，只删 `]`
        XCTAssertEqual(textView.string, "[")
    }

    func testCompletionCommitEatsAutoInsertedClosingBrackets() {
        // 自动配对之后正文是 `[[]]`，光标在中间；补全提交要替换 `[[` 并吃掉多余的 `]]`
        let text = "[[]]"
        let range = NSRange(location: 0, length: 2)
        let full = WikiScanner.commitReplacementRange(range, in: text)
        XCTAssertEqual(full, NSRange(location: 0, length: 4), "必须连光标后的 `]]` 一起替换")

        let ns = text as NSString
        let result = ns.replacingCharacters(in: full, with: "[[双向链接]]")
        XCTAssertEqual(result, "[[双向链接]]", "不能写成 [[双向链接]]]]")

        // 没有自动补的情形保持原样
        let manual = "[[双"
        XCTAssertEqual(
            WikiScanner.commitReplacementRange(NSRange(location: 0, length: 3), in: manual),
            NSRange(location: 0, length: 3)
        )
    }

    func testOtherCharactersAreUntouched() {
        let (textView, _) = makeTextView("")
        type("(", into: textView)
        type("a", into: textView)
        XCTAssertEqual(textView.string, "(a", "本次只处理 `[`，其他字符不擅自配对")
    }

    // MARK: - 2. ⌘ 悬停引用变手型

    func testWikiLinkProvidesCursorRect() {
        let text = "看 [[另一篇]] 的结论"
        let (textView, _) = makeTextView(text)
        let link = WikiScanner.scan(text).first
        XCTAssertNotNil(link)
        guard let link else { return }
        textView.wikiHitRects = [(link.nsRange(in: text), link.target)]
        textView.layoutSubtreeIfNeeded()

        let rects = textView.wikiLinkCursorRects()
        XCTAssertFalse(rects.isEmpty, "单行引用应给出一块矩形")
        guard let rect = rects.first else { return }
        XCTAssertGreaterThan(rect.width, 5, "矩形宽度应覆盖整个引用（实际 \(rect.width)）")
        XCTAssertGreaterThan(rect.height, 5)

        // 矩形要落在引用文字上：命中点应能解析回同一个目标
        let point = NSPoint(x: rect.midX, y: rect.midY)
        let index = textView.characterIndexForInsertion(at: point)
        XCTAssertTrue(index >= link.nsRange(in: text).location
                      && index < link.nsRange(in: text).location + link.nsRange(in: text).length,
                      "矩形不能偏到引用之外（命中字符 \(index)）")
    }

    func testNoWikiLinkMeansNoCursorRect() {
        let (textView, _) = makeTextView("普通正文，没有引用")
        XCTAssertTrue(textView.wikiLinkCursorRects().isEmpty)
    }

    func testCursorRectsFollowTextChanges() {
        let text = "看 [[另一篇]]"
        let (textView, _) = makeTextView(text)
        guard let link = WikiScanner.scan(text).first else { return XCTFail("没扫到引用") }
        textView.wikiHitRects = [(link.nsRange(in: text), link.target)]
        textView.layoutSubtreeIfNeeded()
        XCTAssertFalse(textView.wikiLinkCursorRects().isEmpty)

        // 引用被删掉之后不能再留手型区域
        textView.wikiHitRects = []
        XCTAssertTrue(textView.wikiLinkCursorRects().isEmpty)
    }

    // MARK: - 3. 标题前缀压宽

    func testHeadingMarkerLevelParsing() {
        XCTAssertEqual(HeadingLayout.level(ofMarker: "# "), 1)
        XCTAssertEqual(HeadingLayout.level(ofMarker: "## "), 2)
        XCTAssertEqual(HeadingLayout.level(ofMarker: "### "), 3)
        XCTAssertEqual(HeadingLayout.level(ofMarker: "##   "), 2, "多空格仍是同一级")
    }

    func testHeadingMarkerCompressesToZeroWidth() {
        for marker in ["# ", "## ", "### ", "#   "] {
            let attributes = HeadingLayout.attributes(forMarker: marker, range: NSRange(location: 0, length: marker.count), caretParagraph: nil)
            let width = NSAttributedString(string: marker, attributes: attributes).size().width
            XCTAssertLessThan(width, 0.5, "隐藏态标题前缀「\(marker)」总宽应 ≈0，实际 \(width)")
        }
        // 对照：不压缩时明显更宽，证明上面不是恒真
        let visible = NSAttributedString(
            string: "## ",
            attributes: HeadingLayout.attributes(
                forMarker: "## ",
                range: NSRange(location: 0, length: 3),
                caretParagraph: NSRange(location: 0, length: 5)
            )
        )
        XCTAssertGreaterThan(visible.size().width, 5)
    }

    func testHeadingMarkerVisibleInCaretParagraphOnly() {
        let marker = NSRange(location: 0, length: 3)
        XCTAssertFalse(HeadingLayout.isInCaret(marker, caretParagraph: nil))
        XCTAssertFalse(HeadingLayout.isInCaret(marker, caretParagraph: NSRange(location: 6, length: 4)))
        XCTAssertTrue(HeadingLayout.isInCaret(marker, caretParagraph: NSRange(location: 0, length: 6)))
        // 光标正好在行尾（段落区间含换行）也算在本段
        XCTAssertTrue(HeadingLayout.isInCaret(marker, caretParagraph: NSRange(location: 0, length: 7)))
    }

    func testHeadingTextStartsAtContainerLeftEdge() {
        let text = "## 锻炼\n- [ ] 跑步 3.2k"
        let (textView, _) = makeTextView(text)
        applyHeadings(text, to: textView, caretParagraph: nil)
        textView.layoutSubtreeIfNeeded()

        let origin = textView.textContainerOrigin.x + 5 // 5 = lineFragmentPadding
        let headingX = characterX(textView, at: 3) // 「锻」
        XCTAssertNotNil(headingX)
        XCTAssertEqual(headingX ?? -1, origin, accuracy: 1,
                       "标题正文应贴在左缘，不能被 `## ` 顶出缩进（实际 \(headingX ?? -1)，期望 \(origin)）")

        // 字符一个没少
        XCTAssertEqual(textView.string, text)
    }

    func testHeadingMarkerShowsSourceInsideCaretParagraph() {
        let text = "## 甲\n## 乙"
        let (textView, _) = makeTextView(text)
        let caret = paragraph(text, line: 1)
        applyHeadings(text, to: textView, caretParagraph: caret)
        textView.layoutSubtreeIfNeeded()

        let origin = textView.textContainerOrigin.x + 5
        let second = characterX(textView, at: text.utf16.count - 1) // 「乙」
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(second ?? -1, origin + 5,
                             "光标段落的标题要露出 `## `（实际 \(second ?? -1)）")
    }

    /// 模拟 `Coordinator.applyHeadingMarkers`：直接调生产代码里的属性构造。
    private func applyHeadings(_ text: String, to textView: EditorTextView, caretParagraph: NSRange?) {
        guard let storage = textView.textStorage else { return }
        let ns = text as NSString
        storage.beginEditing()
        storage.setAttributes(Theme.baseAttributes(), range: NSRange(location: 0, length: storage.length))
        for (level, range) in MarkdownStyler.analyze(text).headings {
            storage.addAttributes([
                .font: Theme.headingFont(level: level),
                .paragraphStyle: Theme.headingParagraph(level: level),
            ], range: range)
        }
        for range in MarkdownStyler.headingMarkerRanges(in: text) {
            guard range.location + range.length <= ns.length else { continue }
            let marker = ns.substring(with: range)
            storage.removeAttribute(.kern, range: range)
            storage.addAttributes(
                HeadingLayout.attributes(forMarker: marker, range: range, caretParagraph: caretParagraph),
                range: range
            )
        }
        storage.endEditing()
    }
}
