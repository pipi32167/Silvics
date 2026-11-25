import Foundation

/// 主窗口布局偏好。只存本机，不进 vault。
enum ListPaneSettings {
    private static let key = "silvics.nav.listVisible"

    /// 落盘位置。测试换成独立 suite，避免写真实偏好。
    static var store: UserDefaults = .standard

    /// 列表栏是否展开。默认展开。
    static var isVisible: Bool {
        get { store.object(forKey: key) as? Bool ?? true }
        set { store.set(newValue, forKey: key) }
    }

    private static let widthKey = "silvics.nav.listWidth"
    static let defaultWidth: CGFloat = 232

    /// 列表栏宽度。拖过分隔条就记住，下次打开还原。
    static var width: CGFloat {
        get {
            let raw = store.object(forKey: widthKey) as? Double
            return CGFloat(raw.map { min(max($0, 200), 360) } ?? Double(defaultWidth))
        }
        set { store.set(Double(newValue), forKey: widthKey) }
    }
}
