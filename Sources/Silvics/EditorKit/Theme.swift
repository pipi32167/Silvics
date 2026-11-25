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
        p.firstLineHeadIndent = 14
        p.headIndent = 14
        return p
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
