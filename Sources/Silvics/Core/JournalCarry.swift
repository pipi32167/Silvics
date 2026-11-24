import Foundation

/// 承接：把「上一个有日记的日子」里未完成的待办搬进新日记的最前面。
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

    /// 把承接块插到正文最前。
    ///
    /// 文首没有上一行，所以不补前置空行；块后面已有内容时留一个空行。
    /// 已有同名承接段、或没有未完成项时原样返回，调用方可以用 `!==` 判断有没有插入。
    static func insert(into body: String, from date: String, items: [String]) -> String {
        guard !items.isEmpty else { return body }
        let title = heading(from: date)
        guard !body.contains(title) else { return body }

        var lines = body.components(separatedBy: "\n")
        var payload = [title] + items.map { "- [ ] \($0)" }
        let nextIsBlank = lines.first.map {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        } ?? true
        if !nextIsBlank { payload.append("") }
        lines.insert(contentsOf: payload, at: 0)
        return lines.joined(separator: "\n")
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
