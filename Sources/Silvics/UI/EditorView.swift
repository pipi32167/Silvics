import AppKit
import SwiftUI

// MARK: - 文本视图

/// 编辑用的 NSTextView。
///
/// 只加两件事：⌘ 点击打开引用、Esc 关闭补全。
/// 其余行为全部交给 AppKit，这是选原生技术栈的收益。
final class EditorTextView: NSTextView {

    /// 点击的引用目标标题。由 Coordinator 提供解析。
    var onOpenWikiLink: ((String) -> Void)?
    /// 已解析的引用区间与目标。用于点击命中判定。
    var wikiHitRects: [(NSRange, String)] = []
    /// 当前笔记的未链接提及区间。`⌘⇧K` 按光标命中判定。
    var mentionRanges: [NSRange] = []
    /// Esc 时先通知补全面板。
    var onEscape: (() -> Bool)?
    /// `⌘⇧K`：把光标所在提及转成引用。返回 true 表示已处理。
    var onConvertMention: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let target = wikiTarget(at: event) {
            onOpenWikiLink?(target)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains([.command, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "k",
           onConvertMention?() == true {
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)), onEscape?() == true {
            return
        }
        super.doCommand(by: selector)
    }

    /// 光标所在的提及区间。光标在区间左闭右开范围内算命中。
    func mentionRangeAtCaret() -> NSRange? {
        let index = selectedRange().location
        return mentionRanges.first { index >= $0.location && index < $0.location + $0.length }
    }

    private func wikiTarget(at event: NSEvent) -> String? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index != NSNotFound else { return nil }
        for (range, target) in wikiHitRects {
            if index >= range.location && index < range.location + range.length {
                return target
            }
        }
        return nil
    }
}

// MARK: - SwiftUI 桥

struct NoteEditorView: NSViewRepresentable {

    /// 正文初值。只在创建时读一次，之后由编辑器自己持有。
    let initialText: String
    /// 当前正文。外部改写（批量转换、改名、撤销）后要同步进来。
    let text: String
    /// 已解析的引用目标键集合。决定引用是实线还是虚线。
    let resolvedKeys: Set<String>
    /// 当前笔记的未链接提及。画点状下划线，`⌘⇧K` 转换。
    let mentions: [MentionDecoration]
    /// 外观设置。变化时重排样式（字号、行距、字体族）。
    let appearance: AppearanceSettings
    /// 用户每改一个字就回报一次。
    var onChange: (String) -> Void
    /// 补全查询。
    var completionProvider: (String, Int) -> [CompletionItem]
    /// 采纳「新建《X》」时先建笔记，返回标题。
    var onCreateNote: (String) -> String?
    /// ⌘ 点击引用。
    var onOpenLink: (String) -> Void
    /// 补全是否展开。交给外部观察，用于状态栏提示。
    var onCompletionVisibilityChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder

        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 28, height: 24)

        // 富文本：需要区间属性。但粘贴一律降级为纯文本。
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesRuler = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.font = Theme.bodyFont
        textView.typingAttributes = Theme.typingAttributes()
        textView.string = initialText
        textView.delegate = context.coordinator
        textView.onOpenWikiLink = { [weak coordinator = context.coordinator] title in
            coordinator?.handleOpenLink(title)
        }
        textView.onEscape = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.dismissCompletion()
        }
        textView.onConvertMention = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return false }
            return coordinator.convertMentionAtCaret()
        }

        scrollView.documentView = textView
        context.coordinator.attach(textView: textView, scrollView: scrollView)
        context.coordinator.restyle(force: true)

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? EditorTextView else { return }

        // 外部改过正文（批量转换、改名、启用别名、撤销）时同步进来。
        if textView.string != text {
            let caret = min(textView.selectedRange().location, (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            context.coordinator.didReceiveExternalText(text)
            context.coordinator.restyle(force: true)
        } else if context.coordinator.lastResolvedKeys != resolvedKeys
                    || context.coordinator.lastMentions != mentions
                    || context.coordinator.lastAppearance != appearance {
            context.coordinator.restyle(force: true)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditorView
        private(set) weak var textView: EditorTextView?
        private weak var scrollView: NSScrollView?
        private let completion = CompletionPanelController()

        private var isApplyingStyles = false
        private var completionRange: NSRange?
        private var currentQuery: String = ""
        /// 上一次算出来的语法标记（与光标无关的部分），光标移动时只需重新分桶。
        private var lastSyntaxMarkers: [NSRange] = []
        /// 上一次的分桶依据，避免同段落内的每次光标移动都重设属性。
        private var lastCaretParagraph: NSRange?

        /// 上一次回报给外部的正文，用于避免回环。
        fileprivate var lastPublishedText: String = ""
        fileprivate var lastResolvedKeys: Set<String> = []
        fileprivate var lastMentions: [MentionDecoration] = []
        fileprivate var lastAppearance = AppearanceSettings()

        init(_ parent: NoteEditorView) {
            self.parent = parent
            self.lastPublishedText = parent.initialText
            self.lastResolvedKeys = parent.resolvedKeys
            self.lastMentions = parent.mentions
            self.lastAppearance = parent.appearance
        }

        /// 外部改了正文（DB 侧改写），同步记录避免被当成用户输入再存一次。
        func didReceiveExternalText(_ text: String) {
            lastPublishedText = text
        }

        /// 视图被销毁（切换笔记、窗口关闭）时收掉浮层，断开代理。
        func teardown() {
            completion.hide()
            textView?.delegate = nil
            textView = nil
            scrollView = nil
        }

        func attach(textView: EditorTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
        }

        /// `⌘⇧K`：把光标所在提及转成 `[[引用]]`。走 `shouldChangeText`，可撤销。
        func convertMentionAtCaret() -> Bool {
            guard let textView,
                  let range = textView.mentionRangeAtCaret(),
                  let decoration = parent.mentions.first(where: { $0.range == range }) else {
                return false
            }
            let replacement = "[[\(decoration.title)]]"
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
            textView.textStorage?.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(
                location: range.location + (replacement as NSString).length,
                length: 0
            ))
            return true
        }

        func handleOpenLink(_ title: String) {
            parent.onOpenLink(title)
        }

        func dismissCompletion() -> Bool {
            guard completion.isVisible else { return false }
            completion.hide()
            parent.onCompletionVisibilityChange?(false)
            return true
        }

        // MARK: 样式

        /// 重排全篇属性。
        ///
        /// 语法标记按光标段落分两组：光标所在段落用可读色，其余段落 `.clear`
        /// （字符宽度不变，文本一个不动）。光标移动不走这里，走 `refreshSyntaxMarksForCaret`。
        func restyle(force: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            guard !isApplyingStyles else { return }
            // 中文输入法组合期间不改属性、不重设 typingAttributes（I01–I04）。
            guard !textView.hasMarkedText() else { return }
            isApplyingStyles = true
            defer { isApplyingStyles = false }

            let text = storage.string
            lastPublishedText = text
            lastResolvedKeys = parent.resolvedKeys
            lastMentions = parent.mentions
            lastAppearance = parent.appearance

            let spans = MarkdownStyler.analyze(text)
            let wikis = WikiScanner.scan(text)
            let fullRange = NSRange(location: 0, length: storage.length)
            let caretParagraph = paragraphRange(at: textView.selectedRange().location)
            let marks = MarkdownStyler.syntaxMarkerRanges(
                in: text,
                caretParagraph: caretParagraph,
                spans: spans,
                links: wikis
            )

            let selection = textView.selectedRanges
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            storage.beginEditing()

            storage.setAttributes(Theme.baseAttributes(), range: fullRange)

            applyHeadings(spans, storage, fullRange)
            applyInline(spans, storage, fullRange)
            applyBlocks(spans, in: text, storage, fullRange)
            applyWikiLinks(wikis, in: text, storage, fullRange)
            applyMentions(storage)
            applySyntaxMarks(marks, storage)

            storage.endEditing()
            undoManager?.enableUndoRegistration()

            lastSyntaxMarkers = marks.all
            lastCaretParagraph = caretParagraph

            textView.typingAttributes = Theme.typingAttributes()
            textView.selectedRanges = selection

            // 记录引用命中区间，供 ⌘ 点击使用
            textView.wikiHitRects = wikis.map { link in
                (link.nsRange(in: text), link.target)
            }
            textView.mentionRanges = parent.mentions.map(\.range)
        }

        /// 未链接提及：淡色点状下划线（设计文档 5.4）。
        private func applyMentions(_ storage: NSTextStorage) {
            for decoration in parent.mentions {
                guard let r = clamp(decoration.range, storage.length) else { continue }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: Theme.mentionUnderline,
                ], range: r)
            }
        }

        /// 语法标记可见性：光标段落露出来，其余藏起来。只改字色，不改字符。
        private func applySyntaxMarks(_ marks: SyntaxMarkVisibility, _ storage: NSTextStorage) {
            for range in marks.hide {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarkHidden, range: r)
            }
            for range in marks.show {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttribute(.foregroundColor, value: Theme.syntaxMarkActive, range: r)
            }
        }

        /// 光标换了段落才重刷标记可见性。不重解析 Markdown，不碰选区，不碰 typingAttributes。
        private func refreshSyntaxMarksForCaret() {
            guard let textView, let storage = textView.textStorage else { return }
            guard !isApplyingStyles, !textView.hasMarkedText() else { return }
            guard !lastSyntaxMarkers.isEmpty else { return }
            let caretParagraph = paragraphRange(at: textView.selectedRange().location)
            guard caretParagraph != lastCaretParagraph else { return }

            let marks = MarkdownStyler.split(lastSyntaxMarkers, caretParagraph: caretParagraph)
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            storage.beginEditing()
            applySyntaxMarks(marks, storage)
            storage.endEditing()
            undoManager?.enableUndoRegistration()
            lastCaretParagraph = caretParagraph
        }

        /// 光标位置所在段落的区间（含行尾换行，与 `NSString.paragraphRange(for:)` 一致）。
        private func paragraphRange(at location: Int) -> NSRange? {
            guard let textView else { return nil }
            let ns = textView.string as NSString
            guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
            let clamped = min(max(0, location), ns.length)
            return ns.paragraphRange(for: NSRange(location: clamped, length: 0))
        }

        private func applyHeadings(_ spans: EditorSpans, _ storage: NSTextStorage, _ full: NSRange) {
            for (level, range) in spans.headings {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttributes([
                    .font: Theme.headingFont(level: level),
                    .paragraphStyle: Theme.headingParagraph(level: level),
                ], range: r)
            }
            // `#` 前缀的颜色统一在 `applySyntaxMarks` 里按光标段落处理。
        }

        private func applyInline(_ spans: EditorSpans, _ storage: NSTextStorage, _ full: NSRange) {
            // 粗体：保留现有字号，只加粗
            for range in spans.strongs {
                guard let r = clamp(range, storage.length) else { continue }
                storage.enumerateAttribute(.font, in: r) { value, subRange, _ in
                    guard let font = value as? NSFont else { return }
                    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    storage.addAttribute(.font, value: bold, range: subRange)
                }
            }
            // 斜体：同样保留字号
            for range in spans.emphases {
                guard let r = clamp(range, storage.length) else { continue }
                storage.enumerateAttribute(.font, in: r) { value, subRange, _ in
                    guard let font = value as? NSFont else { return }
                    let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    storage.addAttribute(.font, value: italic, range: subRange)
                }
            }
            // 行内代码
            for range in spans.inlineCodes {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttributes([
                    .font: Theme.codeFont,
                    .backgroundColor: Theme.codeBackground,
                    .foregroundColor: Theme.secondaryText,
                ], range: r)
            }
            // 普通 Markdown 链接
            for range in spans.markdownLinks {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: r)
            }
        }

        private func applyBlocks(
            _ spans: EditorSpans,
            in text: String,
            _ storage: NSTextStorage,
            _ full: NSRange
        ) {
            for range in spans.codeBlocks {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttributes([
                    .font: Theme.codeFont,
                    .backgroundColor: Theme.codeBackground,
                    .paragraphStyle: Theme.codeParagraph(),
                ], range: r)
            }
            applyCodeTokens(spans, in: text, storage)
            for range in spans.blockQuotes {
                guard let r = clamp(range, storage.length) else { continue }
                storage.addAttributes([
                    .foregroundColor: Theme.secondaryText,
                    .paragraphStyle: Theme.quoteParagraph(),
                ], range: r)
            }
        }

        /// 代码块上色。围栏行不碰，只给内容行按 `CodeLexer` 的 token 改字色。
        /// `plain` 不上色，保留正文色。
        private func applyCodeTokens(_ spans: EditorSpans, in text: String, _ storage: NSTextStorage) {
            let ns = text as NSString
            for region in MarkdownStyler.codeBlockRegions(in: text, spans: spans) {
                guard region.contentRange.location >= 0,
                      region.contentRange.location + region.contentRange.length <= ns.length else { continue }
                let code = ns.substring(with: region.contentRange)
                let base = region.contentRange.location
                for token in CodeLexer.lex(code, language: region.language) {
                    guard let color = Theme.tokenColor(token.kind) else { continue }
                    let range = NSRange(location: base + token.range.location, length: token.range.length)
                    guard let r = clamp(range, storage.length) else { continue }
                    storage.addAttribute(.foregroundColor, value: color, range: r)
                }
            }
        }

        /// 引用样式：方括号淡化，标题着色加下划线。悬空用虚线。
        private func applyWikiLinks(
            _ links: [WikiLink],
            in text: String,
            _ storage: NSTextStorage,
            _ full: NSRange
        ) {
            for link in links {
                let whole = link.nsRange(in: text)
                guard let r = clamp(whole, storage.length), r.length >= 4 else { continue }
                let inner = NSRange(location: r.location + 2, length: r.length - 4)

                let resolved = parent.resolvedKeys.contains(TextNormalizer.key(link.target))
                let color = resolved ? Theme.linkText : Theme.danglingText
                let underline: NSUnderlineStyle = resolved ? .single : [.single, .patternDash]

                // 整段先给链接色
                storage.addAttributes([
                    .foregroundColor: color,
                    .underlineStyle: underline.rawValue,
                    .underlineColor: color,
                ], range: r)

                // 内部文字稍重，方括号退到语法色
                storage.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: inner
                )
                // 方括号的颜色交给 `applySyntaxMarks` 统一处理（按光标段落显示或隐藏）
                storage.addAttributes([
                    .underlineStyle: 0,
                ], range: NSRange(location: r.location, length: 2))
                storage.addAttributes([
                    .underlineStyle: 0,
                ], range: NSRange(location: r.location + r.length - 2, length: 2))

                // 显示名与锚点淡化
                if link.display != nil || link.anchor != nil {
                    storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: inner)
                }
            }
        }

        private func clamp(_ range: NSRange, _ length: Int) -> NSRange? {
            guard range.location >= 0, range.location <= length else { return nil }
            let maxLen = length - range.location
            guard maxLen > 0 else { return nil }
            return NSRange(location: range.location, length: min(range.length, maxLen))
        }

        // MARK: 文本变化

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? EditorTextView else { return }
            let text = textView.string
            restyle(force: false)
            parent.onChange(text)
            refreshCompletionIfNeeded()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // 光标移动要重算「哪一段露源码」，但不能重排全篇（否则滚动会跳）。
            refreshSyntaxMarksForCaret()
            // 光标移动时刷新补全的候选（在同一条引用内左右移动）
            if completion.isVisible {
                refreshCompletionIfNeeded()
            }
        }

        // MARK: 补全

        /// 光标前若是一段未闭合的 `[[`，返回它的起点与查询串。
        private func activeWikiContext() -> (range: NSRange, query: String)? {
            guard let textView else { return nil }
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location > 0 else { return nil }
            let ns = textView.string as NSString
            let lookback = min(selection.location, 80)
            let start = selection.location - lookback
            let window = ns.substring(with: NSRange(location: start, length: lookback))
            guard let found = window.range(of: "[[", options: .backwards) else { return nil }

            let offsetInWindow = window.distance(from: window.startIndex, to: found.lowerBound)
            let afterOpen = String(window[found.upperBound...])
            if afterOpen.contains("]]") || afterOpen.contains("\n") { return nil }

            let absoluteOpen = start + offsetInWindow
            let queryLength = selection.location - absoluteOpen - 2
            guard queryLength >= 0 else { return nil }
            let query = ns.substring(with: NSRange(location: absoluteOpen + 2, length: queryLength))
            return (NSRange(location: absoluteOpen, length: selection.location - absoluteOpen), query)
        }

        private func refreshCompletionIfNeeded() {
            guard let textView else { DebugLog.write("refresh: no textView"); return }
            guard let context = activeWikiContext() else {
                DebugLog.write("refresh: no active context, caret=\(textView.selectedRange())")
                if completion.isVisible {
                    completion.hide()
                    parent.onCompletionVisibilityChange?(false)
                }
                completionRange = nil
                return
            }

            completionRange = context.range
            currentQuery = context.query
            let items = parent.completionProvider(context.query, 8)
            DebugLog.write("refresh: query=\(context.query) items=\(items.count) range=\(context.range)")
            guard !items.isEmpty else {
                completion.hide()
                parent.onCompletionVisibilityChange?(false)
                return
            }
            let anchor = caretAnchorRect(in: textView)
            completion.show(items: items, anchor: anchor, in: textView) { [weak self] item in
                self?.commit(item)
            }
            if !completion.isVisible {
                parent.onCompletionVisibilityChange?(true)
            }
        }

        private func caretAnchorRect(in textView: NSTextView) -> NSRect {
            let selection = textView.selectedRange()
            let glyphRange = textView.layoutManager?.glyphRange(
                forCharacterRange: NSRange(location: max(0, selection.location), length: 0),
                actualCharacterRange: nil
            ) ?? NSRange(location: 0, length: 0)
            var rect = textView.layoutManager?.boundingRect(
                forGlyphRange: glyphRange, in: textView.textContainer!
            ) ?? .zero
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            if rect.height <= 0 { rect.size.height = 18 }
            return rect
        }

        private func commit(_ item: CompletionItem) {
            guard let textView, let range = completionRange else { return }
            completion.hide()
            parent.onCompletionVisibilityChange?(false)

            var title = item.title
            if item.isCreate {
                guard let created = parent.onCreateNote(title) else { return }
                title = created
            }

            let replacement = "[[\(title)]]"
            let full = NSRange(location: range.location, length: range.length)
            if textView.shouldChangeText(in: full, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: full, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: full.location + (replacement as NSString).length, length: 0))
            }
            completionRange = nil
        }

        // MARK: 按键拦截

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard completion.isVisible else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                completion.move(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                completion.move(1)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                if let item = completion.selectedItem { commit(item) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                completion.hide()
                parent.onCompletionVisibilityChange?(false)
                return true
            default:
                return false
            }
        }
    }
}
