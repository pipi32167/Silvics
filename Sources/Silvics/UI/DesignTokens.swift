import AppKit
import SwiftUI

/// 设计 token：颜色、字阶、间距、圆角。
///
/// 只收视觉参数，不含业务。所有界面从这里取，不再各写 `Color.accentColor` 与写死字号。
/// 颜色按「浅色 / 深色」两套解析，跟随系统外观；主题色来自外观设置。
///
/// 取值与 `docs/设计-视觉规范.md` 的一一对应，改这里要同步改那张表。
enum Tokens {

    // MARK: - 主题色

    // MARK: - 调色板

    /// 一套配色的全部色值。**深浅色各存一份**，取用时按当前外观解析。
    struct Palette {
        let lightPaper: NSColor
        let lightRail: NSColor
        let lightPanel: NSColor
        let lightAccent: NSColor
        let lightInk: NSColor
        let lightInk2: NSColor
        let lightInk3: NSColor
        let lightHair: NSColor

        let darkPaper: NSColor
        let darkRail: NSColor
        let darkPanel: NSColor
        let darkAccent: NSColor
        let darkInk: NSColor
        let darkInk2: NSColor
        let darkInk3: NSColor
        let darkHair: NSColor

        func paper(_ dark: Bool) -> NSColor { dark ? darkPaper : lightPaper }
        func rail(_ dark: Bool) -> NSColor { dark ? darkRail : lightRail }
        func panel(_ dark: Bool) -> NSColor { dark ? darkPanel : lightPanel }
        func accent(_ dark: Bool) -> NSColor { dark ? darkAccent : lightAccent }
        func ink(_ dark: Bool) -> NSColor { dark ? darkInk : lightInk }
        func ink2(_ dark: Bool) -> NSColor { dark ? darkInk2 : lightInk2 }
        func ink3(_ dark: Bool) -> NSColor { dark ? darkInk3 : lightInk3 }
        func hair(_ dark: Bool) -> NSColor { dark ? darkHair : lightHair }
    }

    /// 当前主题色。由 `AppState` 在启动与改设置时写入。
    private(set) static var theme: AppearanceSettings.ThemeColor = .moss

    static func apply(theme: AppearanceSettings.ThemeColor) {
        self.theme = theme
    }

    /// 当前是否深色外观。取窗口实际生效的外观，不读 UserDefaults。
    static var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - 颜色

    static var paper: Color { Color(nsColor: theme.palette.paper(isDark)) }
    static var rail: Color { Color(nsColor: theme.palette.rail(isDark)) }
    static var panel: Color { Color(nsColor: theme.palette.panel(isDark)) }
    static var accent: Color { Color(nsColor: theme.palette.accent(isDark)) }
    static var ink: Color { Color(nsColor: theme.palette.ink(isDark)) }
    static var ink2: Color { Color(nsColor: theme.palette.ink2(isDark)) }
    static var ink3: Color { Color(nsColor: theme.palette.ink3(isDark)) }
    static var hair: Color { Color(nsColor: theme.palette.hair(isDark)) }

    /// 选中态底色：主色 13%（深色 16%）。比 `accent.opacity` 稳，深浅两套都读过对比度。
    static var selectedFill: Color {
        accent.opacity(isDark ? 0.18 : 0.13)
    }

    // MARK: - 字体

    /// 正文衬线族。标题、列表标题、阅读正文用它；控件仍用系统无衬线。
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let name = serifFontName {
            return .custom(name, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// 中文衬线优先宋体，找不到再退回系统衬线。
    static var serifFontName: String? {
        for name in ["Songti SC", "STSong", "Songti TC"] where NSFont(name: name, size: 12) != nil {
            return name
        }
        return nil
    }

    // MARK: - 字阶（大小, 字重）

    enum TypeScale {
        /// 阅读正文 16.5 / 行高 1.75。
        static let prose = (size: CGFloat(16.5), lineHeight: CGFloat(1.75))
        /// 编辑器标题 15。
        static let title = (size: CGFloat(15), weight: Font.Weight.semibold)
        /// 列表标题 13.5。
        static let listTitle = (size: CGFloat(13.5), weight: Font.Weight.regular)
        /// 界面正文 12.5。
        static let body = (size: CGFloat(12.5), weight: Font.Weight.regular)
        /// 小标签 11。
        static let label = (size: CGFloat(11), weight: Font.Weight.medium)
        /// 计数与快捷键 9.5。
        static let meta = (size: CGFloat(9.5), weight: Font.Weight.regular)
    }

    // MARK: - 间距与圆角

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
    }

    enum Radius {
        static let row: CGFloat = 7
        static let card: CGFloat = 8
        static let panel: CGFloat = 12
    }

    static func hex(_ value: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 主题色 → 色值

extension AppearanceSettings.ThemeColor {
    /// 一套配色的浅色与深色值。数值见 `docs/设计-视觉规范.md`，改这里要同步那张表。
    var palette: Tokens.Palette {
        switch self {
        case .moss:
            return Tokens.Palette(
                lightPaper: Tokens.hex(0xF9FAF3), lightRail: Tokens.hex(0xF1F3E7), lightPanel: Tokens.hex(0xFFFFFF),
                lightAccent: Tokens.hex(0x2F6B4F), lightInk: Tokens.hex(0x232720), lightInk2: Tokens.hex(0x68705F),
                lightInk3: Tokens.hex(0x868980), lightHair: Tokens.hex(0xDEE2D1),
                darkPaper: Tokens.hex(0x16180F), darkRail: Tokens.hex(0x1D2016), darkPanel: Tokens.hex(0x1E2118),
                darkAccent: Tokens.hex(0x86C7A2), darkInk: Tokens.hex(0xE9E8DF), darkInk2: Tokens.hex(0xA9AE9D),
                darkInk3: Tokens.hex(0x7E8474), darkHair: Tokens.hex(0x2C3024)
            )
        case .indigo:
            return Tokens.Palette(
                lightPaper: Tokens.hex(0xF9FAFD), lightRail: Tokens.hex(0xEFF2F9), lightPanel: Tokens.hex(0xFFFFFF),
                lightAccent: Tokens.hex(0x2C5FD1), lightInk: Tokens.hex(0x1F2430), lightInk2: Tokens.hex(0x68708A),
                lightInk3: Tokens.hex(0x838790), lightHair: Tokens.hex(0xDDE2EE),
                darkPaper: Tokens.hex(0x121620), darkRail: Tokens.hex(0x181D29), darkPanel: Tokens.hex(0x1A1F2C),
                darkAccent: Tokens.hex(0x8AA8F0), darkInk: Tokens.hex(0xE6E9F2), darkInk2: Tokens.hex(0xA3AABE),
                darkInk3: Tokens.hex(0x77809A), darkHair: Tokens.hex(0x272E3D)
            )
        case .lilac:
            return Tokens.Palette(
                lightPaper: Tokens.hex(0xFBF9FD), lightRail: Tokens.hex(0xF3EFFA), lightPanel: Tokens.hex(0xFFFFFF),
                lightAccent: Tokens.hex(0x6B5ACF), lightInk: Tokens.hex(0x262233), lightInk2: Tokens.hex(0x706A86),
                lightInk3: Tokens.hex(0x888493), lightHair: Tokens.hex(0xE4DEF0),
                darkPaper: Tokens.hex(0x16131E), darkRail: Tokens.hex(0x1C1826), darkPanel: Tokens.hex(0x1F1A2A),
                darkAccent: Tokens.hex(0xB3A6F0), darkInk: Tokens.hex(0xE9E5F2), darkInk2: Tokens.hex(0xABA4BE),
                darkInk3: Tokens.hex(0x807A93), darkHair: Tokens.hex(0x2B2538)
            )
        case .clay:
            return Tokens.Palette(
                lightPaper: Tokens.hex(0xFAF7F0), lightRail: Tokens.hex(0xF2EDE3), lightPanel: Tokens.hex(0xFFFFFF),
                lightAccent: Tokens.hex(0x6F5B49), lightInk: Tokens.hex(0x2A2620), lightInk2: Tokens.hex(0x6B6357),
                lightInk3: Tokens.hex(0x88847C), lightHair: Tokens.hex(0xDCD3C2),
                darkPaper: Tokens.hex(0x18150F), darkRail: Tokens.hex(0x1E1A13), darkPanel: Tokens.hex(0x211C15),
                darkAccent: Tokens.hex(0xC8AC8C), darkInk: Tokens.hex(0xEDE7DC), darkInk2: Tokens.hex(0xB5AC9C),
                darkInk3: Tokens.hex(0x857D6E), darkHair: Tokens.hex(0x2E2820)
            )
        case .graphite:
            return Tokens.Palette(
                lightPaper: Tokens.hex(0xF8F8F7), lightRail: Tokens.hex(0xF0F0EF), lightPanel: Tokens.hex(0xFFFFFF),
                lightAccent: Tokens.hex(0x3F4A56), lightInk: Tokens.hex(0x1F2226), lightInk2: Tokens.hex(0x6B7076),
                lightInk3: Tokens.hex(0x858788), lightHair: Tokens.hex(0xE2E2E1),
                darkPaper: Tokens.hex(0x141517), darkRail: Tokens.hex(0x1A1B1D), darkPanel: Tokens.hex(0x1D1E21),
                darkAccent: Tokens.hex(0x9FB0C0), darkInk: Tokens.hex(0xE7E8EA), darkInk2: Tokens.hex(0xA6A9AE),
                darkInk3: Tokens.hex(0x7C8085), darkHair: Tokens.hex(0x292B2E)
            )
        }
    }

    /// 设置页色卡用的代表色（浅色版主色）。
    var swatch: NSColor { palette.accent(false) }
}
