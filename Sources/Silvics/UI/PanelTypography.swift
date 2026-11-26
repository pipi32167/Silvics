import SwiftUI

/// 右栏（详情页 / AI 页）与弹窗预览的字号。
///
/// 字号来自外观设置的「面板字号」（`AppearanceSettings.panelSize`），
/// 调用方只取语义级别，不写字号：正文 `text`、标签 `label`、注脚 `meta`。
/// 字体族跟随同一份设置，正文选衬线时面板也跟着衬线。
enum PanelFont {

    /// 面板字号。改设置后 `AppState` 会 `Theme.apply` 并重发通知，视图随之重算。
    static var base: CGFloat { CGFloat(Theme.appearance.panelSize) }

    /// 正文：AI 消息、摘要编辑框、提示词输入。
    static func text(_ weight: Font.Weight = .regular) -> Font {
        font(base, weight)
    }

    /// 标签：小节标题、页签、按钮文案。
    static func label(_ weight: Font.Weight = .regular) -> Font {
        font(max(base - 1.5, 10), weight)
    }

    /// 注脚：模型名、网址、条数这类元信息。
    static func meta(_ weight: Font.Weight = .regular) -> Font {
        font(max(base - 3, 9), weight)
    }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch Theme.appearance.fontFamily {
        case .system: return .system(size: size, weight: weight)
        case .serif: return .system(size: size, weight: weight, design: .serif)
        case .mono: return .system(size: size, weight: weight, design: .monospaced)
        }
    }
}
