import Foundation

/// 承接：把「上一个有日记的日子」里未完成的待办搬进新日记。
///
/// 新建日记插在文首；在已有日记里手动插入时插在光标所在行之前（C02 / C06）。
///
/// 语义对齐原型 `prototype/journal/app.js` 的 `openTodosIn` / `carryLines` / `insertCarry`：
///
/// - 只认 `[-*+] [ ]` 形式的未完成项；`[x]` / `[X]` 已完成，不搬。
/// - 代码块里的 `- [ ]` 不算待办。
/// - 承接块结构固定：`## 承接（来自 MM-DD）` 加每条一行 `- [ ] 条目`。
/// - 已有同名承接段就不重复插入；来源那天没有未完成项就不插入。
enum JournalCarry {

    /// 正文里的未完成待办，按出现顺序。
    static func openTodos(in body: String) -> [String] {
        var items: [String] = []
        var inFence = false
        for line in body.components(separatedBy: "\n") {
            if isFence(line) {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            guard let todo = todoItem(line), !todo.done else { continue }
            items.append(todo.text)
        }
        return items
    }

    /// 承接段的标题。日期取后 5 位（`2026-11-23` → `11-23`）。
    static func heading(from date: String) -> String {
        let suffix = date.count >= 10 ? String(date.suffix(5)) : date
        return "## 承接（来自 \(suffix)）"
    }

    /// 插入结果：新正文、光标该落的行、有没有真的插入。
    struct Insertion: Equatable {
        var body: String
        /// 承接块之后的那一行（0-based）。没插入时等于传入的 `beforeLine`。
        var caretLine: Int
        var didInsert: Bool
    }

    /// 把承接块插到正文最前。新建日记走这条，等价于 `beforeLine: 0`。
    ///
    /// 文首没有上一行，所以不补前置空行；块后面已有内容时留一个空行。
    /// 已有同名承接段、或没有未完成项时原样返回，调用方可以用 `!==` 判断有没有插入。
    static func insert(into body: String, from date: String, items: [String]) -> String {
        insertion(into: body, beforeLine: 0, from: date, items: items).body
    }

    /// 把承接块插到第 `beforeLine` 行之前。行按 `\n` 分，0 是文首。
    ///
    /// 空行规则对齐原型 `insertCarry`：上一行非空就补一个空行，下一行非空就补一个空行；
    /// 已经是空行时不重复补，所以不会出现连续两个空行。
    /// 已有同名承接段、或没有未完成项时原样返回（`didInsert == false`），不抛错。
    static func insertion(into body: String, beforeLine: Int, from date: String, items: [String]) -> Insertion {
        let at = max(0, beforeLine)
        let unchanged = Insertion(body: body, caretLine: at, didInsert: false)
        guard !items.isEmpty else { return unchanged }
        guard !hasCarry(in: body, from: date) else { return unchanged }

        var lines = body.components(separatedBy: "\n")
        let index = min(at, lines.count)
        let previousIsBlank = index == 0
            || lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty
        let nextIsBlank = index >= lines.count
            || lines[index].trimmingCharacters(in: .whitespaces).isEmpty

        var payload: [String] = []
        if !previousIsBlank { payload.append("") }
        payload.append(heading(from: date))
        payload.append(contentsOf: items.map { "- [ ] \($0)" })
        if !nextIsBlank { payload.append("") }

        lines.insert(contentsOf: payload, at: index)
        return Insertion(
            body: lines.joined(separator: "\n"),
            caretLine: index + payload.count,
            didInsert: true
        )
    }

    /// 正文里有没有这一天的承接段。判重只看标题，不看条目。
    static func hasCarry(in body: String, from date: String) -> Bool {
        body.contains(heading(from: date))
    }

    /// UTF-16 偏移 → 行号（0-based，行按 `\n` 分）。偏移越界时夹到正文范围。
    ///
    /// `NSRange` 一律是 UTF-16 单位，光标位置来自 `NSTextView.selectedRange()`，
    /// 所以这里也按 UTF-16 数，不能按 `body.count`（字符 / 字形）数。
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

    // MARK: - 行解析

    private static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    /// 解析 `[-*+] [ ] 文本`。与原型正则 `^(\s*)[-*+]\s+\[([ xX])\]\s(.*)$` 一致：
    /// `]` 后面必须有一个空白，之后的文本原样（含多余空格）保留。
    private static func todoItem(_ line: String) -> (done: Bool, text: String)? {
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" { rest = rest.dropFirst() }
        guard let marker = rest.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        rest = rest.dropFirst()
        guard let spacer = rest.first, spacer == " " || spacer == "\t" else { return nil }
        while let c = rest.first, c == " " || c == "\t" { rest = rest.dropFirst() }

        guard rest.first == "[" else { return nil }
        rest = rest.dropFirst()
        guard let mark = rest.first, mark == " " || mark == "x" || mark == "X" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == "]" else { return nil }
        rest = rest.dropFirst()
        guard let separator = rest.first, separator == " " || separator == "\t" else { return nil }
        rest = rest.dropFirst()

        return (mark != " ", String(rest))
    }
}
