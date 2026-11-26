import AppKit
import XCTest
@testable import Silvics

/// 中文输入法吞字（issue #34）。
///
/// 症状：用系统拼音打字，上屏的词偶尔整段消失。
/// 根因：`updateNSView` 拿「视图正文 != 传入正文」当判据同步外部正文，
/// 而 SwiftUI 会把上一轮渲染算出的旧快照再跑一次 `updateNSView`，
/// 那时视图里已经是刚上屏的字，按旧快照重设就把它冲掉了。
///
/// 修复后只认 `AppState.bodyRevision`：用户敲字不动它，外部改写才加一。
@MainActor
final class EditorIMETests: XCTestCase {

    /// 用例编号：I05（组合期外部改写）、I06（旧快照落地）—— 见 `docs/日记编辑器边界用例.md`。

    // MARK: - 工具

    private func makeEditor(_ text: String) -> (EditorTextView, NSScrollView, NoteEditorView.Coordinator) {
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
        textView.string = text

        let parent = NoteEditorView(
            initialText: text,
            text: text,
            textRevision: 1,
            liveText: nil,
            resolvedKeys: [],
            mentions: [],
            appearance: AppearanceSettings(),
            onChange: { _ in },
            completionProvider: { _, _ in [] },
            onCreateNote: { _ in nil },
            onOpenLink: { _ in },
            onCompletionVisibilityChange: { _ in }
        )
        let coordinator = makeCoordinator(parent)
        textView.delegate = coordinator
        coordinator.attach(textView: textView, scrollView: scrollView)
        coordinator.restyle(force: true)
        return (textView, scrollView, coordinator)
    }

    private func makeCoordinator(_ parent: NoteEditorView) -> NoteEditorView.Coordinator {
        parent.makeCoordinator()
    }

    /// 走系统输入法的两步：组合态 → 上屏。
    private func imeType(_ word: String, into textView: EditorTextView) {
        let pinyin = "nihao"
        textView.setMarkedText(
            pinyin,
            selectedRange: NSRange(location: (pinyin as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        textView.insertText(word, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func moveCaretToEnd(_ textView: EditorTextView) {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    // MARK: - I01 上屏不吞字

    /// 旧实现按「视图 != 传入」同步，这个用例在旧代码上会红：
    /// 快照 `旧正文` 被写回视图，刚上屏的词消失。
    func testStaleSnapshotDoesNotOverwriteTypedText() {
        let (textView, _, coordinator) = makeEditor("第一段。")
        moveCaretToEnd(textView)

        imeType("你好", into: textView)
        XCTAssertEqual(textView.string, "第一段。你好", "上屏后视图就该有这两个字")

        // SwiftUI 用同一份旧快照又跑了一遍 updateNSView：版本号没变，不该动视图。
        let handled = coordinator.syncExternalText("第一段。", revision: 1)
        XCTAssertFalse(handled, "版本号没变就不算外部改写")
        XCTAssertEqual(textView.string, "第一段。你好", "旧快照不得覆盖用户刚敲的字")
        XCTAssertEqual(textView.selectedRange().location, 6, "光标停在字后")
    }

    /// 连续上屏多个词，每一步都不许回退。
    func testConsecutiveIMECommitsAccumulate() {
        let (textView, _, coordinator) = makeEditor("")
        let words = ["你好", "世界", "输入法", "吞字"]
        for word in words {
            moveCaretToEnd(textView)
            imeType(word, into: textView)
            _ = coordinator.syncExternalText("", revision: 1)
        }
        XCTAssertEqual(textView.string, words.joined())
        XCTAssertEqual(textView.selectedRange().location, (words.joined() as NSString).length)
    }

    // MARK: - I05 外部改写要能同步进来

    func testExternalRevisionAppliesNewBody() {
        let (textView, _, coordinator) = makeEditor("第一段。")
        moveCaretToEnd(textView)
        imeType("你好", into: textView)

        // 改名、批量转换这类真实外部改写：版本号变了才落。
        XCTAssertTrue(coordinator.syncExternalText("改名之后的正文。", revision: 2))
        XCTAssertEqual(textView.string, "改名之后的正文。")
        XCTAssertEqual(coordinator.appliedRevision, 2)
    }

    /// 同一个版本号只落一次，重复的 updateNSView 不反复重排。
    func testSameRevisionAppliedOnce() {
        let (textView, _, coordinator) = makeEditor("甲")
        XCTAssertTrue(coordinator.syncExternalText("乙", revision: 2))
        XCTAssertFalse(coordinator.syncExternalText("丙", revision: 2), "版本号没变不再写")
        XCTAssertEqual(textView.string, "乙")
    }

    // MARK: - I02 组合态里不写正文

    func testExternalBodyWaitsForCompositionToEnd() {
        let (textView, _, coordinator) = makeEditor("第一段。")
        moveCaretToEnd(textView)
        textView.setMarkedText(
            "nihao",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())

        XCTAssertTrue(coordinator.syncExternalText("外部改写的正文。", revision: 2))
        XCTAssertEqual(textView.string, "第一段。nihao", "组合没结束就不能改写正文")
        XCTAssertTrue(textView.hasMarkedText(), "组合态要保住")

        // 组合期内用户自己上屏：以用户敲的字为准，排队的外部正文作废，
        // 但版本号要记账，避免下一轮又拿同一个版本反复试。
        imeType("你好", into: textView)
        XCTAssertEqual(textView.string, "第一段。你好", "上屏替换组合串")
        XCTAssertEqual(coordinator.appliedRevision, 2, "作废也要记账")
    }

    /// 组合态里用户自己敲字了：以视图为准，排队的外部正文作废。
    func testTypingDuringPendingExternalKeepsUserText() {
        let (textView, _, coordinator) = makeEditor("第一段。")
        moveCaretToEnd(textView)
        textView.setMarkedText(
            "nihao",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        _ = coordinator.syncExternalText("外部改写的正文。", revision: 2)

        imeType("你好", into: textView)

        let done = expectation(description: "等一下排队任务")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(textView.string, "第一段。你好", "用户敲的字优先")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    // MARK: - AppState 的版本号语义

    func testBodyRevisionBumpsOnlyOnExternalReload() throws {
        let vault = TempVault("revision")
        let db = try AppDatabase.makeInMemory()
        let repo = vault.repo(db)
        let note = try repo.create(title: "版本号")
        let app = AppState(repo: repo)

        app.loadAll(selectFirst: true)
        let afterLoad = app.bodyRevision

        // 用户敲字：不算外部改写。
        app.bodyDidChange("用户敲的字")
        XCTAssertEqual(app.bodyRevision, afterLoad, "用户输入不得递增版本号")

        // 从库里重读：算外部改写。
        app.loadNote(id: note.id)
        XCTAssertGreaterThan(app.bodyRevision, afterLoad, "重载要递增版本号")
    }
}
