import AppKit

/// 标题前缀（`#` 加其后空格）的呈现规则。
///
/// 与列表标记同一套：光标段落露源码，其余段落把前缀压到 ≈0 宽，
/// 标题正文从容器左缘开始，不再被 `##` 顶出一个缩进（issue #8）。
/// 纯函数，属性构造只此一处，渲染与测试共用。
enum HeadingLayout {

    /// 前缀里有几个 `#`。夹在 1–3，与 `MarkdownStyler` 的标题级别一致。
    static func level(ofMarker marker: String) -> Int {
        let hashes = marker.prefix(while: { $0 == "#" }).count
        return max(1, min(3, hashes))
    }

    /// 前缀是否落在光标段落里。落在里面就露源码，否则压宽。
    static func isInCaret(_ marker: NSRange, caretParagraph: NSRange?) -> Bool {
        guard let caret = caretParagraph, caret.length > 0 else { return false }
        return marker.location < caret.location + caret.length
            && caret.location < marker.location + marker.length
    }

    /// 前缀该用哪套属性。
    ///
    /// 可见态只改颜色，字号仍是标题字号 —— 露出来的是源码，不是正文。
    /// 隐藏态与列表标记共用 `Theme.compressedMarkerAttributes`：字号 0.1 加负 kern。
    static func attributes(
        forMarker marker: String,
        range: NSRange,
        caretParagraph: NSRange?
    ) -> [NSAttributedString.Key: Any] {
        guard isInCaret(range, caretParagraph: caretParagraph) else {
            return Theme.compressedMarkerAttributes(for: marker)
        }
        return [
            .font: Theme.headingFont(level: level(ofMarker: marker)),
            .foregroundColor: Theme.syntaxMarkActive,
        ]
    }
}
