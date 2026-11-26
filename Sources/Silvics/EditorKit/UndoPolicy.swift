import Foundation

/// 撤销步的切分规则（issue #35）。
///
/// 为什么需要它：`NSTextView` 把一个「连续键入回合」合成一个撤销步，
/// 而且不按时间断开。实测（本机 macOS 27 / TextKit 2）：每字间隔 1 秒打 5 个字，
/// 一次 ⌘Z 仍然全部清空。用户写完整篇再按 ⌘Z，正文就整篇没了。
///
/// 这里只回答一个问题：这次改完之后要不要 `breakUndoCoalescing()`。
/// 纯函数，不碰 AppKit，边界值都有单测。
public enum UndoPolicy {

    /// 一步最多装多少个字符。超过就断开。
    ///
    /// 40 的取法：一屏中文约 30–40 字，正好是「回退一段」的心理单位。
    /// 再大就会退掉半篇；再小则一句话要按好几次 ⌘Z。
    public static let maxCharactersPerStep = 40

    /// 停笔多久算一步。定时器在编辑器里跑，这里只给值。
    public static let idleInterval: TimeInterval = 1.5

    /// 断句字符：这些字符之后断开，一次撤销退回一个分句。
    ///
    /// 中英文都算上，因为笔记里两种都会出现。
    private static let boundaries: Set<Character> = [
        "\n", "\r", " ",
        "。", "，", "、", "；", "：", "！", "？", "…", "—",
        ".", ",", ";", ":", "!", "?",
        ")", "）", "]", "】", "」", "』",
    ]

    /// 这次插入的尾巴是不是落在断句边界上。
    public static func endsAtBoundary(_ tail: String) -> Bool {
        guard let last = tail.last else { return false }
        return boundaries.contains(last)
    }

    /// 要不要断开当前撤销步。
    ///
    /// - Parameters:
    ///   - tail: 本次改动插入的文字（删除时传空串）。
    ///   - charactersSinceBreak: 自从上次断开以来累计改动过的字符数（取绝对值）。
    /// - Returns: true 表示调用方应在 `didChangeText()` 之后 `breakUndoCoalescing()`。
    public static func shouldBreak(tail: String, charactersSinceBreak: Int) -> Bool {
        if charactersSinceBreak >= maxCharactersPerStep { return true }
        return endsAtBoundary(tail)
    }
}
