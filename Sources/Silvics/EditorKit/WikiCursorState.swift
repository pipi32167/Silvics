import AppKit

/// 引用上指针形状的判定。
///
/// 只由「当前是否按住 ⌘」和「指针是否落在引用上」两个输入决定，不记上一次的状态。
/// 之前用实例变量缓存上一次的 ⌘ 状态，就在「编辑视图重建」时出错：
/// 建视图那一刻按住的 ⌘ 会被记成初值，之后真正按下 / 松开反而被判成「没变化」而跳过（issue #8）。
struct WikiCursorState: Equatable {

    /// 当前是否按住 ⌘。
    var commandHeld: Bool
    /// 指针是否落在引用上。
    var overLink: Bool

    /// 该主动设置的指针。`nil` 表示不干预，交给 AppKit 按 cursor rect 处理。
    var cursor: NSCursor? {
        guard overLink else { return nil }
        return commandHeld ? .pointingHand : .iBeam
    }

    /// 是否要把引用区注册成手型 cursor rect。
    var registersHandRects: Bool { commandHeld }
}
