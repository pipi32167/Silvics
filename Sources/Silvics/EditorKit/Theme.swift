import AppKit

/// 编辑区与侧栏的视觉常量。
///
/// 语义色固定，自动跟随系统深浅色。字体与段落来自 `AppearanceSettings`：
/// 先 `Theme.apply(settings)`，再取 `bodyFont` / `codeFont` / `headingFont(level:)`。
/// 样式只在渲染期生效，不写进正文。
enum Theme {

    private(set) static var appearance = AppearanceSettings()

    /// 应用外观设置。只在主线程调用。
    static func apply(_ settings: AppearanceSettings) {
        appearance = settings.clamped
    }

    // MARK: - 字体

    static var bodySize: CGFloat { CGFloat(appearance.bodySize) }
    static var bodyFont: NSFont { font(ofSize: bodySize, weight: .regular) }
    static var codeFont: NSFont { monoFont(size: CGFloat(appearance.codeSize)) }

    /// 正文字体族。`mono` 用于代码，正文与标题只取 system / serif。
    static func font(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        switch appearance.fontFamily {
        case .system:
            return base
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .serif:
            guard let descriptor = base.fontDescriptor.withDesign(.serif),
                  let serif = NSFont(descriptor: descriptor, size: size) else { return base }
            return serif
        }
    }

    static func monoFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func headingSize(level: Int) -> CGFloat {
        CGFloat(appearance.headingSize(level: level))
    }

    static func headingFont(level: Int) -> NSFont {
        let size = headingSize(level: level)
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        return font(ofSize: size, weight: weight)
    }

    // MARK: - 颜色

    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let tertiaryText = NSColor.tertiaryLabelColor
    /// 语法符号（`#`、`**`、`[[`）的淡色。现在只剩「光标行露源码」之外的地方用。
    static let syntaxMark = NSColor.quaternaryLabelColor

    /// 光标所在段落的语法符号：比正文（`labelColor`）淡一档，仍可读、可改。
    static let syntaxMarkActive = NSColor.secondaryLabelColor

    /// 非光标段落的语法符号：完全不可见。字符还在，宽度不变。
    static let syntaxMarkHidden = NSColor.clear

    /// 有效引用。
    static let linkText = NSColor(name: "linkText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.48, green: 0.78, blue: 0.62, alpha: 1)
            : NSColor(red: 0.10, green: 0.42, blue: 0.28, alpha: 1)
    }

    /// 悬空引用（指向还不存在的笔记）。
    static let danglingText = NSColor(name: "danglingText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.62, green: 0.62, blue: 0.66, alpha: 1)
            : NSColor(red: 0.48, green: 0.48, blue: 0.52, alpha: 1)
    }

    /// 未链接提及的淡下划线色。
    static let mentionUnderline = NSColor(name: "mentionUnderline") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1)
            : NSColor(red: 0.62, green: 0.48, blue: 0.08, alpha: 1)
    }

    static let codeBackground = NSColor(name: "codeBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07)
            : NSColor(white: 0, alpha: 0.045)
    }

    static let quoteBar = NSColor(name: "quoteBar") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.18)
            : NSColor(white: 0, alpha: 0.12)
    }

    // MARK: - 表格

    /// 表格字号固定 13pt：列宽与 kern 都按这个字号的字宽度量，跟正文 / 代码字号脱钩。
    static let tableFontSize: CGFloat = 13

    static var tableFont: NSFont { NSFont.monospacedSystemFont(ofSize: tableFontSize, weight: .regular) }
    static var tableHeaderFont: NSFont { NSFont.monospacedSystemFont(ofSize: tableFontSize, weight: .bold) }

    /// pipe 的淡色。对齐验收要靠截图里的 pipe，所以不能设成 `.clear`。
    static let tablePipe = NSColor(name: "tablePipe") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.38)
            : NSColor(white: 0, alpha: 0.32)
    }

    /// 分隔行 `| --- |`：淡化到 40%，光标行恢复 `labelColor`。
    static let tableDelimiter = NSColor(name: "tableDelimiter") { appearance in
        NSColor.labelColor.withAlphaComponent(0.4)
    }

    /// 表头行下方的淡分隔线（下划线）。
    static let tableHeaderRule = NSColor(name: "tableHeaderRule") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.30)
            : NSColor(white: 0, alpha: 0.22)
    }

    /// 表格行的段落样式。
    ///
    /// `lineBreakMode = .byClipping`：表格行一旦软换行，后面半行会掉到下一视觉行，
    /// pipe 就永远对不齐。宁可横向裁掉，也不让列错位。
    static func tableParagraph(first: Bool, last: Bool) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 1
        p.paragraphSpacingBefore = first ? 8 : 0
        p.paragraphSpacing = last ? 8 : 0
        p.lineBreakMode = .byClipping
        return p
    }

    // MARK: - 代码高亮
    //
    // 只改字色，不改字符。深色模式下一律抬高亮度、降饱和，避免浅底配色在暗底上刺眼。

    /// 关键字（`let`、`func`、`return`、`\frac`）。
    static let tokenKeyword = NSColor(name: "tokenKeyword") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.83, green: 0.58, blue: 0.98, alpha: 1)
            : NSColor(red: 0.52, green: 0.13, blue: 0.62, alpha: 1)
    }

    /// 字符串（含三引号、模板字符串）。
    static let tokenString = NSColor(name: "tokenString") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.94, green: 0.62, blue: 0.46, alpha: 1)
            : NSColor(red: 0.66, green: 0.20, blue: 0.10, alpha: 1)
    }

    /// 注释（`//`、`#`、`%`、`/* */`）。压亮度，不与正文抢注意力。
    static let tokenComment = NSColor(name: "tokenComment") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.56, green: 0.66, blue: 0.58, alpha: 1)
            : NSColor(red: 0.38, green: 0.47, blue: 0.40, alpha: 1)
    }

    /// 数字（`42`、`0x1F`、`1e-3`）。
    static let tokenNumber = NSColor(name: "tokenNumber") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.56, green: 0.73, blue: 0.99, alpha: 1)
            : NSColor(red: 0.10, green: 0.30, blue: 0.72, alpha: 1)
    }

    /// 函数名（标识符后紧跟 `(`）。
    static let tokenFunction = NSColor(name: "tokenFunction") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.47, green: 0.83, blue: 0.86, alpha: 1)
            : NSColor(red: 0.06, green: 0.40, blue: 0.44, alpha: 1)
    }

    /// token 类别 → 字色。`plain` 返回 `nil`：调用方跳过，保留正文色。
    static func tokenColor(_ kind: CodeTokenKind) -> NSColor? {
        switch kind {
        case .keyword: return tokenKeyword
        case .string: return tokenString
        case .comment: return tokenComment
        case .number: return tokenNumber
        case .function: return tokenFunction
        case .plain: return nil
        }
    }

    // MARK: - 段落

    static func bodyParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = CGFloat(appearance.lineSpacing)
        p.paragraphSpacing = 9
        p.lineBreakMode = .byWordWrapping
        return p
    }

    static func headingParagraph(level: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.paragraphSpacingBefore = level <= 2 ? 16 : 12
        p.paragraphSpacing = 6
        return p
    }

    static func codeParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        p.paragraphSpacingBefore = 6
        p.paragraphSpacing = 10
        p.firstLineHeadIndent = 10
        p.headIndent = 10
        return p
    }

    static func quoteParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.paragraphSpacing = 8
        // 与列表同一套缩进：标记压缩后正文从 `ListLayout.indent` 开始，换行也对齐。
        p.firstLineHeadIndent = ListLayout.indent
        p.headIndent = ListLayout.indent
        collapseTabStops(in: p)
        return p
    }

    /// 列表行（无序 / 有序 / 待办）的段落样式。
    ///
    /// `firstLineHeadIndent` 与 `headIndent` 相同：首行与软换行后的行左缘一致。
    /// 标记字符由 `compressedMarkerAttributes(for:)` 压到宽度 ≈ 0，空出来的位置交给自绘符号。
    static func listParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = CGFloat(appearance.lineSpacing)
        p.paragraphSpacing = 9
        p.lineBreakMode = .byWordWrapping
        p.firstLineHeadIndent = ListLayout.indent
        p.headIndent = ListLayout.indent
        collapseTabStops(in: p)
        return p
    }

    /// 把列表 / 引用段落里的制表位压到最小。
    ///
    /// tab 缩进（`\t- 甲`）按制表位跳格走，跟字号、kern 都无关，压宽压不住它：
    /// 默认制表位每隔 28 pt 一格，行首那个 tab 白白占 6 pt（5 + 缩进 22 → 下一个格 28）。
    /// 这里清空自定义制表位、把默认间隔压到 0.1 pt，行首 tab 只剩 0.1 pt。
    ///
    /// 不能写 0：实测制表位间隔为 0 时 TextKit 2 不再为这一段产出 `textLineFragments`，
    /// 整段量不到位置（`EditorIndentTests` 的 tab 用例会直接量不到 x）。
    /// 代价：这两类段落里行中间的 tab 不再对到制表位——列表正文里几乎不会用到。
    static func collapseTabStops(in paragraph: NSMutableParagraphStyle) {
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 0.1
    }

    // MARK: - 行首标记的两种宽度

    /// 隐藏态标记的字号。小到几乎只剩字形原点，配负 kern 把总宽压到 0。
    static let hiddenMarkerFont = NSFont.systemFont(ofSize: 0.1)

    private static var markerKernCache: [String: CGFloat] = [:]

    /// 让一段标记的总宽 ≈ 0 的 kern 值：`-总宽 / 字符数`。
    ///
    /// kern 在 AppKit 里是每个字形之后都加一次，所以除以字符数即可。
    /// 结果按标记原文缓存：正文重排时不会重新测量（按键不重测全篇）。
    static func compressedMarkerKern(for marker: String) -> CGFloat {
        guard !marker.isEmpty else { return 0 }
        if let cached = markerKernCache[marker] { return cached }
        let width = (marker as NSString).size(withAttributes: [.font: hiddenMarkerFont]).width
        let kern = -width / CGFloat(marker.utf16.count)
        if markerKernCache.count > 512 { markerKernCache.removeAll(keepingCapacity: true) }
        markerKernCache[marker] = kern
        return kern
    }

    /// 隐藏态标记属性：字号 0.1 + 负 kern + 无色。字符一个不动。
    static func compressedMarkerAttributes(for marker: String) -> [NSAttributedString.Key: Any] {
        [
            .font: hiddenMarkerFont,
            .kern: compressedMarkerKern(for: marker),
            .foregroundColor: syntaxMarkHidden,
        ]
    }

    /// 可见态标记的排版宽度。光标段落露源码时，正文就右移这么多（S37）。
    static func visibleMarkerWidth(_ marker: String) -> CGFloat {
        (marker as NSString).size(withAttributes: visibleMarkerAttributes()).width
    }

    /// 光标段落里的标记属性：正常字号、没有 kern（S37）。
    static func visibleMarkerAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: syntaxMarkActive,
        ]
    }

    // MARK: - 基础属性

    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: text,
            .paragraphStyle: bodyParagraph(),
        ]
    }

    /// 光标处新输入字符的默认属性。避免继承上一段的粗体或标题样式。
    static func typingAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: text,
            .paragraphStyle: bodyParagraph(),
        ]
    }
}
