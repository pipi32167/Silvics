import Foundation

/// 行首列表的识别结果（S28–S38）。
///
/// 只描述「这一行的前缀长什么样」，不做嵌套、不做重新编号：
/// 有序列表保留原文序号（S38），缩进只记录不参与布局（S35）。
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
    /// 隐藏（非光标段落）时整段压到宽度 ≈ 0，正文因此从 `ListLayout.indent` 处开始。
    var markerRange: NSRange

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

    /// 列表正文的固定左缩进。软换行后的第二行也落在同一位置。
    static let indent: CGFloat = 22

    /// 待办复选框边长。
    static let checkboxSize: CGFloat = 14

    /// 无序列表符号（实心圆）直径。
    static let bulletDiameter: CGFloat = 5

    /// 要画项目符号 / 序号的列表行（待办另画复选框）。
    static func markersToRender(_ markers: [ListMarker], caretParagraph: NSRange?) -> [ListMarker] {
        markers.filter { marker in
            guard !marker.isTodo else { return false }
            return !isInCaretParagraph(marker, caretParagraph)
        }
    }

    /// 要画待办复选框的列表行。光标段落不画（改为露源码），S40。
    static func checkboxTodos(_ markers: [ListMarker], caretParagraph: NSRange?) -> [ListMarker] {
        markers.filter { marker in
            guard marker.isTodo else { return false }
            return !isInCaretParagraph(marker, caretParagraph)
        }
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

    /// 竖线离正文容器左缘的距离。
    static let barInset: CGFloat = 7
}
