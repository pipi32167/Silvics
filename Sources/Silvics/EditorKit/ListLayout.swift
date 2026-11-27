import Foundation

/// 行首列表的识别结果（S28–S38）。
///
/// 只描述「这一行的前缀长什么样」。层级按缩进算（issue #50），有序列表保留原文序号（S38）。
struct ListMarker: Equatable {
    enum Kind: Equatable {
        case unordered
        case ordered(Int)
        case todo(checked: Bool)

        var isTodo: Bool {
            if case .todo = self { return true }
            return false
        }
    }

    var kind: Kind
    /// 行首缩进量（视觉宽度：空格记 1，制表符记 4）。只记录，不参与缩进布局。
    var indent: Int
    /// 行首缩进的字符数。区间计算只能用它：一个 tab 是 1 个字符、4 个宽度（issue #41）。
    var indentChars: Int
    /// 整段前缀区间：缩进 + 项目符号 / 序号 / 勾选框 + 后随空格。
    /// 隐藏（非光标段落）时整段压到宽度 ≈ 0，正文因此从 `ListLayout.offset(level:)` 处开始。
    var markerRange: NSRange
    /// 嵌套层级，从 1 起。2 空格或 1 个 tab 算一级，最多 `ListLayout.maxLevel` 级（issue #50）。
    var level: Int = 1

    /// 去掉缩进后的前缀区间。语法标记（`-`、`1.`、`- [ ] `）用这个。
    var visibleRange: NSRange {
        let drop = min(indentChars, markerRange.length)
        return NSRange(location: markerRange.location + drop, length: markerRange.length - drop)
    }

    var orderedNumber: Int? {
        if case .ordered(let number) = kind { return number }
        return nil
    }

    var isTodo: Bool { kind.isTodo }
}

/// 列表与引用的固定布局量。
///
/// 项目符号与复选框都是自绘的：`NSTextList` 在 TextKit 2 下只加缩进、不画标记
/// （实测见 `docs/日记编辑器边界用例.md` S28–S41 的说明与验收报告）。
enum ListLayout {

    /// 一层列表的额外缩进。
    ///
    /// 0 表示与标题、正文同一条左缘（issue #50）。第 1 版是 22，导致列表 / 待办 / 引用的正文
    /// 比标题和段落右移一截，用户看到的就是「前置空白」。
    static let indent: CGFloat = 0

    /// 每深一级增加的缩进。第 2 级 18、第 3 级 36。
    static let levelStep: CGFloat = 18

    /// 支持的最大层级。更深的缩进按第 3 级排（不做无限缩进）。
    static let maxLevel = 3

    /// 项目符号 / 复选框 / 引用竖线到正文左缘的距离。装饰物挂在这条间隙里，不占正文位置。
    static let gutter: CGFloat = 22

    /// 待办复选框边长。比正文略小一号，简体与宋体下都看得清（issue #50 要求再大一点）。
    static let checkboxSize: CGFloat = 17

    /// 无序列表符号（实心圆）直径。
    static let bulletDiameter: CGFloat = 5

    /// 某一级的额外缩进量。
    static func offset(level: Int) -> CGFloat {
        let clamped = min(max(level, 1), maxLevel)
        return indent + CGFloat(clamped - 1) * levelStep
    }

    /// 由行首缩进原文算层级：2 个空格或 1 个 tab 算一级。
    ///
    /// 层级只影响左缘位置与符号形状，不改正文、不改语义（S35 的延续）。
    static func level(forIndent chars: Substring) -> Int {
        var units = 0
        for ch in chars {
            units += ch == "\t" ? 2 : 1
        }
        return min(max(1 + units / 2, 1), maxLevel)
    }

    /// 回车续行时要写的下一段前缀（不含行首缩进）。
    ///
    /// - 无序：原文照搬。
    /// - 有序：序号 +1，`.` / `)` 与后随空格照搬。
    /// - 待办：无论当前是否勾选，新条目一律未勾选。
    static func nextMarkerText(for marker: ListMarker, original: String) -> String {
        switch marker.kind {
        case .unordered:
            return original
        case .ordered(let number):
            let digits = String(number)
            if let range = original.range(of: digits) {
                return original.replacingCharacters(in: range, with: String(number + 1))
            }
            return original
        case .todo:
            // `- [x] ` → `- [ ] `：只换方括号里那一个字符。
            guard let open = original.firstIndex(of: "["),
                  let close = original.firstIndex(of: "]"),
                  original.distance(from: open, to: close) == 2 else { return original }
            var out = original
            let boxIndex = original.index(after: open)
            out.replaceSubrange(boxIndex...boxIndex, with: " ")
            return out
        }
    }

    /// 要画项目符号 / 序号的列表行（待办另画复选框）。
    ///
    /// 与光标无关：标记永远不露源码（对齐 Typora）。
    /// 早先光标进这一行会改成一个字面 `- `，行内文字立刻右移 10 pt，续行不动，段内错位。
    static func markersToRender(_ markers: [ListMarker], caretParagraph: NSRange?) -> [ListMarker] {
        _ = caretParagraph
        return markers.filter { !$0.isTodo }
    }

    /// 要画待办复选框的列表行。
    ///
    /// 与光标无关：光标进待办行时复选框仍要在（否则那一下既丢了可点区域，又把正文推右 28 pt）。
    static func checkboxTodos(_ markers: [ListMarker], caretParagraph: NSRange?) -> [ListMarker] {
        _ = caretParagraph
        return markers.filter(\.isTodo)
    }

    /// 行首缩进：编辑器里永远不占宽。
    ///
    /// 光标段落原来会把整段前缀（含缩进）恢复原宽，于是 `  - 甲` 一进编辑态正文就右移 8 pt，
    /// 光标移开又缩回去（issue #41）。缩进是排版噪声，改成无论光标在哪都不占宽，
    /// 光标段落只恢复语法标记本身（`- `、`1. `、`- [ ] `）。
    /// 缩进的压宽属性与标记同一套构造，只此一处。
    static func indentAttributes(for indent: String) -> [NSAttributedString.Key: Any] {
        Theme.compressedMarkerAttributes(for: indent)
    }

    /// 光标段落内的标记不隐藏、不画符号、不画复选框：那一段露源码。
    static func isInCaretParagraph(_ marker: ListMarker, _ caretParagraph: NSRange?) -> Bool {
        guard let caret = caretParagraph, caret.length > 0 else { return false }
        let start = marker.markerRange.location
        let end = start + marker.markerRange.length
        let caretEnd = caret.location + caret.length
        return start < caretEnd && caret.location < end
    }
}

/// 引用（`> `）块的竖向装饰线布局量。
enum QuoteLayout {
    /// 左侧竖线宽度。
    static let barWidth: CGFloat = 2

    /// 竖线到正文左缘的距离（往左）。挂在 `ListLayout.gutter` 里，正文因此与标题同左缘。
    static let barInset: CGFloat = 9
}
