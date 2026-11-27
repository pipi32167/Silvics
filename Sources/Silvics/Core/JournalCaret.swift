import Foundation

/// 编辑区行号与 UTF-16 偏移的换算。
///
/// `NSRange` 一律是 UTF-16 单位，光标来自 `NSTextView.selectedRange()`，
/// 所以这里按 UTF-16 数，不按 `String.count`（字符 / 字形）数，否则中文与 emoji 会错位。
enum JournalCaret {

    /// UTF-16 偏移 → 行号（0-based，行按 `\n` 分）。偏移越界时夹到正文范围。
    static func lineIndex(ofUTF16Offset offset: Int, in body: String) -> Int {
        let text = body as NSString
        let clamped = max(0, min(offset, text.length))
        return text.substring(to: clamped).components(separatedBy: "\n").count - 1
    }

    /// 行号 → 该行行首的 UTF-16 偏移。行号越界返回 nil。
    static func utf16Offset(ofLine line: Int, in body: String) -> Int? {
        let lines = body.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { return nil }
        var offset = 0
        for index in 0..<line {
            offset += (lines[index] as NSString).length + 1
        }
        return offset
    }
}
