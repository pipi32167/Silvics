import AppKit
import XCTest
@testable import Silvics

/// 日记编辑器「光标行露源码」的语法标记可见性。
///
/// 编号与 `docs/日记编辑器边界用例.md` 对齐（S 组 = 语法识别，E19 = Home/End）。
/// 这里测的是纯函数：给了文本与光标段落，哪些标记该显示、哪些该隐藏。
/// 隐藏只改字色（`.clear`），不改字符 —— 下面有多条用例守着「文本与宽度不变」。
final class JournalSyntaxMarkerTests: XCTestCase {

    // MARK: - 工具

    /// 第 `line` 行（0 起）所在段落的区间。
    private func paragraph(_ text: String, line: Int) -> NSRange {
        let ns = text as NSString
        var offset = 0
        var current = 0
        while current < line {
            let newline = ns.range(of: "\n", options: [], range: NSRange(location: offset, length: ns.length - offset))
            guard newline.location != NSNotFound else { break }
            offset = newline.location + 1
            current += 1
        }
        return ns.paragraphRange(for: NSRange(location: offset, length: 0))
    }

    private func texts(_ ranges: [NSRange], in text: String) -> [String] {
        let ns = text as NSString
        return ranges.map { ns.substring(with: $0) }
    }

    private func visibility(_ text: String, caretLine: Int?) -> SyntaxMarkVisibility {
        MarkdownStyler.syntaxMarkerRanges(
            in: text,
            caretParagraph: caretLine.map { paragraph(text, line: $0) }
        )
    }

    // MARK: - S01–S05 标题

    func testS01HeadingMarkerShownOnCaretParagraph() {
        let text = "## 工作\n正文一段。"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(marks.show, [NSRange(location: 0, length: 3)])
        XCTAssertTrue(marks.hide.isEmpty)
        XCTAssertEqual(texts(marks.show, in: text), ["## "])
    }

    func testS02TagWithoutSpaceIsNotHeading() {
        let text = "#工作"
        let marks = visibility(text, caretLine: 0)
        XCTAssertTrue(marks.all.isEmpty, "# 后无空格不是标题，标记不该被当成语法符号")
    }

    func testS03FourHashesIsNotHeading() {
        let text = "#### 深"
        XCTAssertTrue(visibility(text, caretLine: 0).all.isEmpty, "只支持 1–3 级，四级当段落")
    }

    func testS04HeadingKeepsExtraSpacesInMarker() {
        let text = "##   工作"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.show, in: text), ["##   "], "多余空格一并算标记，隐藏后不留空档")
    }

    func testS05EmptyHeadingStillHasMarker() {
        let text = "## "
        XCTAssertEqual(texts(visibility(text, caretLine: 0).show, in: text), ["## "])
    }

    func testS21TagIsNotHeadingOnLineStart() {
        // `#标签`（无空格）是标签不是标题。
        let text = "#标签\n正文"
        XCTAssertTrue(visibility(text, caretLine: 1).all.isEmpty)
    }

    // MARK: - S06–S10 待办

    func testS06TodoMarkerShownOnCaretParagraph() {
        let text = "- [ ] a"
        XCTAssertEqual(texts(visibility(text, caretLine: 0).show, in: text), ["- [ ] "])
    }

    func testS07TodoUppercaseXCounts() {
        let text = "- [X] a"
        XCTAssertEqual(texts(visibility(text, caretLine: 0).show, in: text), ["- [X] "])
    }

    func testS08TodoStarBulletCounts() {
        let text = "* [ ] a"
        XCTAssertEqual(texts(visibility(text, caretLine: 0).show, in: text), ["* [ ] "])
    }

    func testS09TodoNeedsSpaceAfterBracket() {
        let text = "- [ ]a"
        XCTAssertTrue(visibility(text, caretLine: 0).all.isEmpty, "`]` 后无空格不算待办")
    }

    func testS10IndentedTodoMarkerStartsAtBullet() {
        let text = "  - [ ] a"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(marks.show, [NSRange(location: 2, length: 6)], "缩进保留，标记从项目符号开始")
        XCTAssertEqual(texts(marks.show, in: text), ["- [ ] "])
    }

    func testS10TodoMarkerHiddenWhenCaretElsewhere() {
        let text = "- [ ] a\n第二段"
        let marks = visibility(text, caretLine: 1)
        XCTAssertTrue(marks.show.isEmpty)
        XCTAssertEqual(texts(marks.hide, in: text), ["- [ ] "])
    }

    // MARK: - S11–S15 链接

    func testS11WikiBracketsSplitByCaretParagraph() {
        let text = "一行 [[a]] 引用\n\n另一段 [[b]] 引用"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.show, in: text), ["[[", "]]"])
        XCTAssertEqual(texts(marks.hide, in: text), ["[[", "]]"])
        XCTAssertEqual(marks.show.map(\.location), [3, 6])
        XCTAssertTrue(marks.hide.allSatisfy { $0.location > 12 })
    }

    func testS12AliasBracketsStillMarked() {
        let text = "见 [[a|显示]]"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.show, in: text), ["[[", "]]"], "显示名不是语法标记")
    }

    func testS13AnchorBracketsStillMarked() {
        let text = "[[a#锚点]]"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.show, in: text), ["[[", "]]"])
    }

    func testS14UnclosedWikiHasNoMarkers() {
        XCTAssertTrue(visibility("前缀 [[a 后面没有结束", caretLine: 0).all.isEmpty)
    }

    func testS15EmptyWikiHasNoMarkers() {
        XCTAssertTrue(visibility("空的 [[ ]] 不算链接", caretLine: 0).all.isEmpty)
    }

    // MARK: - S16 / S22 行内代码

    func testS16InlineCodeHidesLinkBrackets() {
        let text = "`[[a]]` 不是链接"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.show, in: text), ["`", "`"], "只标记反引号，代码里的 [[ 不处理")
        XCTAssertFalse(marks.show.contains { $0.length == 2 })
    }

    func testS22StrongInsideInlineCodeNotMarked() {
        let text = "`**x**`"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.show, in: text), ["`", "`"], "代码里的星号不加粗，也不当语法标记")
    }

    // MARK: - S17 / S23–S27 代码块围栏

    func testS17HeadingInsideCodeBlockIsNotMarked() {
        let text = "```\n## x\n```"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.all, in: text), ["```", "```"])
        XCTAssertFalse(marks.show.contains { $0.length == 2 }, "块内的 ## 不变标题")
    }

    func testS23FenceWithLanguageMarker() {
        let text = "```swift\nlet a = 1\n```"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.all, in: text), ["```", "```"], "语言标记留着可见")
        XCTAssertEqual(marks.hide.count, 1)
    }

    func testS24UnclosedFenceStillMarked() {
        let text = "```\nlet a = 1"
        XCTAssertEqual(texts(visibility(text, caretLine: 1).all, in: text), ["```"])
    }

    func testS25WikiInsideCodeBlockNotMarked() {
        let text = "```\n[[a]]\n```"
        let marks = visibility(text, caretLine: 1)
        XCTAssertEqual(texts(marks.all, in: text), ["```", "```"])
        XCTAssertFalse(marks.all.contains { $0.length == 2 })
    }

    func testS26InlineFenceIsNotMarker() {
        XCTAssertTrue(visibility("正文 ``` 后面还有字", caretLine: 0).all.isEmpty, "行中间的 ``` 不开启代码块")
    }

    func testS27FourBackticksTreatedAsFence() {
        let text = "````\nx\n````"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(marks.all.map(\.length), [4, 4], "四个反引号按围栏处理")
        XCTAssertEqual(marks.all.count, 2)
    }

    // MARK: - S18 / S19 强调

    func testS18StrongMarkersSplitAroundCaretParagraph() {
        let text = "**粗**\n\n正文"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.show, in: text), ["**", "**"])
        XCTAssertEqual(marks.show, [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
    }

    func testS19UnclosedStrongHasNoMarkers() {
        XCTAssertTrue(visibility("**粗", caretLine: 0).all.isEmpty)
    }

    func testEmphasisMarkers() {
        let text = "*斜* 与 **粗**"
        let marks = visibility(text, caretLine: 0)
        XCTAssertEqual(texts(marks.show, in: text), ["*", "*", "**", "**"])
    }

    // MARK: - 不变量：文本与宽度不变

    func testMarkersNeverOverlapAndStayInsideText() {
        let text = """
        ## 工作 **粗** [[链接|显示]]
        - [ ] 待办 `代码 [[x]]`
        ```swift
        ## 不是标题
        ```
        *斜* 与 [](占位)
        """
        let ns = text as NSString
        let marks = visibility(text, caretLine: 0)
        XCTAssertFalse(marks.all.isEmpty)
        var cursor = 0
        for range in marks.all {
            XCTAssertGreaterThanOrEqual(range.location, cursor, "标记区间必须升序且不重叠")
            XCTAssertLessThanOrEqual(range.location + range.length, ns.length)
            cursor = range.location + range.length
        }
        XCTAssertEqual(marks.show.count + marks.hide.count, marks.all.count)
    }

    func testEveryMarkerSubstringIsPunctuationOnly() {
        let text = "## 工作\n- [ ] 待办 [[链接]]\n```\ncode\n```\n**粗** `行内`"
        let ns = text as NSString
        let allowed = CharacterSet(charactersIn: "#-*+[] xX`~_")
        for range in visibility(text, caretLine: 1).all {
            let piece = ns.substring(with: range)
            XCTAssertFalse(piece.isEmpty)
            XCTAssertTrue(
                piece.unicodeScalars.allSatisfy { allowed.contains($0) },
                "标记区间里不该有正文：「\(piece)」"
            )
        }
    }

    func testHiddenMarkersKeepCharacterCount() {
        let text = "## 工作\n- [ ] 待办 [[链接]]"
        let ns = text as NSString
        let marks = visibility(text, caretLine: 1)
        let hiddenCharacters = marks.hide.reduce(0) { $0 + ($1.length) }
        XCTAssertEqual(ns.length, 21, "分区不改变文本长度")
        XCTAssertEqual(hiddenCharacters, 3, "只有标题的 `## ` 被隐藏")
    }

    func testNilCaretHidesEverything() {
        let text = "## 工作\n- [ ] 待办"
        let marks = MarkdownStyler.syntaxMarkerRanges(in: text, caretParagraph: nil)
        XCTAssertTrue(marks.show.isEmpty)
        XCTAssertEqual(marks.hide.count, 2)
    }

    func testSplitDoesNotNeedReparse() {
        let text = "## 工作\n\n- [ ] 待办"
        let all = MarkdownStyler.syntaxMarkerRanges(in: text, caretParagraph: nil).all
        let split = MarkdownStyler.split(all, caretParagraph: paragraph(text, line: 2))
        XCTAssertEqual(texts(split.show, in: text), ["- [ ] "])
        XCTAssertEqual(texts(split.hide, in: text), ["## "])
    }

    /// 光标换段只改属性：文本长度不变、选区不变、滚动原点不变。
    ///
    /// 真实路径是 `restyle` / `refreshSyntaxMarksForCaret` 向 `NSTextStorage` 写字色。
    /// 这里用真的 `NSTextView` 跑一遍，确认没有顺带改文本、改选区、滚到底。
    func testAttributeOnlyPassKeepsTextSelectionAndScrollOffset() throws {
        let lines = (1...120).map { index in
            index % 3 == 0 ? "## 标题 \(index)" : "- [ ] 待办 \(index)  [[引用\(index)]]"
        }
        let text = lines.joined(separator: "\n")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 4000)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        window.contentView = scrollView
        textView.string = text
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        // 先把滚动条推离原点，否则「没跳动」没意义。
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 900))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let scrollBefore = scrollView.contentView.bounds.origin

        let caret = (text as NSString).range(of: "待办 61").location
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        let selectionBefore = textView.selectedRange()

        let paragraph = (text as NSString).paragraphRange(for: NSRange(location: caret, length: 0))
        let marks = MarkdownStyler.syntaxMarkerRanges(in: text, caretParagraph: nil)
        let split = MarkdownStyler.split(marks.all, caretParagraph: paragraph)
        XCTAssertFalse(split.show.isEmpty)
        XCTAssertFalse(split.hide.isEmpty)

        let storage = try XCTUnwrap(textView.textStorage)
        storage.beginEditing()
        for range in split.hide {
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }
        for range in split.show {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        }
        storage.endEditing()

        XCTAssertEqual(storage.string, text, "只改属性，正文不能变")
        XCTAssertEqual(storage.length, (text as NSString).length)
        XCTAssertEqual(textView.selectedRange(), selectionBefore, "光标不能被挪动")
        XCTAssertEqual(scrollView.contentView.bounds.origin, scrollBefore, "滚动位置不能跳")
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: split.show[0].location, effectiveRange: nil) as? NSColor,
            NSColor.secondaryLabelColor
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: split.hide[0].location, effectiveRange: nil) as? NSColor,
            NSColor.clear
        )
    }

    // MARK: - 颜色常量

    func testSyntaxMarkColorsAreDistinct() {
        XCTAssertNotEqual(Theme.syntaxMarkActive, Theme.syntaxMarkHidden)
        XCTAssertEqual(Theme.syntaxMarkHidden, NSColor.clear, "非光标段落必须完全不可见")
    }

    // MARK: - E19 Home / End

    /// E19 依赖系统行为，本项目不接管。
    ///
    /// `NSTextView` 原生就支持 Home / End（含 `⌘←`、`⌘→` 到段首段尾），
    /// 日记混合模式在 Swift 端不再需要原型里那段手工挪光标逻辑。
    /// 这里断言 `EditorTextView` 没有覆盖这两个动作 —— 一旦有人加上自定义实现，这条会红。
    func testE19HomeEndReliesOnSystemBehaviour() {
        let selectors: [Selector] = [
            #selector(NSResponder.moveToBeginningOfLine(_:)),
            #selector(NSResponder.moveToEndOfLine(_:)),
            #selector(NSResponder.moveToBeginningOfParagraph(_:)),
            #selector(NSResponder.moveToEndOfParagraph(_:)),
        ]
        for selector in selectors {
            let ours = class_getMethodImplementation(EditorTextView.self, selector)
            let system = class_getMethodImplementation(NSTextView.self, selector)
            XCTAssertNotNil(system, "\(selector) 是 NSTextView 原生支持的动作")
            XCTAssertEqual(
                "\(String(describing: ours))",
                "\(String(describing: system))",
                "\(selector) 不该被 EditorTextView 覆盖"
            )
        }
    }
}
