import AppKit

/// 编辑区与侧栏的视觉常量。只用语义色，自动跟随系统深浅色。
enum Theme {

    // MARK: - 字体

    static let bodySize: CGFloat = 15
    static let bodyFont = NSFont.systemFont(ofSize: bodySize)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)

    static func headingFont(level: Int) -> NSFont {
        let sizes: [CGFloat] = [26, 21, 18, 16.5, 15.5, 15]
        let size = sizes[min(max(level, 1), 6) - 1]
        return NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)
    }

    // MARK: - 颜色

    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let tertiaryText = NSColor.tertiaryLabelColor
    /// 语法符号（`#`、`**`、`[[`）的颜色：淡到几乎不干扰阅读。
    static let syntaxMark = NSColor.quaternaryLabelColor

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

    // MARK: - 段落

    static func bodyParagraph() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 5
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
