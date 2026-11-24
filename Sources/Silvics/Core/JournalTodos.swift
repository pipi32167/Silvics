import Foundation

/// 待办总览的一行：跨日记聚合后的同一个条目。
///
/// 「同一句话」按去掉首尾空白后的文本判等。状态取最近一天：最近一天是 `[x]` 就不出现。
struct JournalTodo: Identifiable, Equatable, Hashable {
    var text: String
    /// 最早出现的那天（`YYYY-MM-DD`）。
    var firstDate: String
    /// 最近出现的那天。点击跳到这天。
    var lastDate: String
    /// 出现过的不同天数。
    var dayCount: Int

    var id: String { text }

    /// 总览副标题：`最早 11-21 · 最近 11-24 · 共 3 天`。日期取后 5 位，和承接段一致。
    var detail: String {
        "最早 \(Self.short(firstDate)) · 最近 \(Self.short(lastDate)) · 共 \(dayCount) 天"
    }

    static func short(_ date: String) -> String {
        date.count >= 10 ? String(date.suffix(5)) : date
    }
}

/// 侧栏「日记」列表的一行。
struct JournalEntry: Identifiable, Equatable, Hashable {
    var id: String
    var date: String
    /// `周一` 这种形式。
    var weekday: String
    /// 未完成的待办条数。
    var openTodoCount: Int
}

/// 日记正文里的待办解析与跨日聚合。
///
/// 与 `JournalCarry` 同一条行解析规则（`[-*+] [ ]`，代码块内不算），
/// 但不改 `JournalCarry`：承接只要「未完成 + 文本」，总览还要行区间与完成状态。
enum JournalTodos {

    struct Item: Equatable {
        /// 已勾选（`[x]` / `[X]`）。
        var done: Bool
        /// 去掉首尾空白后的条目文本。同一句话按它判等。
        var text: String
        /// 整行在正文里的 UTF-16 区间。跳过去时用它滚动。
        var range: NSRange
        /// 行号，从 0 开始。
        var lineIndex: Int
    }

    /// 正文里的全部待办，按出现顺序。代码块里的 `- [ ]` 不算。
    static func items(in body: String) -> [Item] {
        var out: [Item] = []
        var offset = 0
        var inFence = false
        let lines = body.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let length = (raw as NSString).length
            defer { offset += length + 1 }
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence, let parsed = parse(line) else { continue }
            out.append(Item(
                done: parsed.done,
                text: parsed.text.trimmingCharacters(in: .whitespaces),
                range: NSRange(location: offset, length: length),
                lineIndex: index
            ))
        }
        return out
    }

    /// 未完成的待办条数。侧栏日记行用。
    static func openCount(in body: String) -> Int {
        items(in: body).filter { !$0.done }.count
    }

    /// 跨日聚合。
    ///
    /// - 输入按日期升序（调用方负责排序，这里也再排一次，避免依赖调用顺序）。
    /// - 同一条目在一天里出现多次只算一天，状态取该天最后一次出现。
    /// - 最终只保留「最近一次出现仍未完成」的条目，按最近日期倒序。
    static func aggregate(_ journals: [(date: String, body: String)]) -> [JournalTodo] {
        struct Record {
            var text: String
            var firstDate: String
            var lastDate: String
            var days: Set<String>
            var done: Bool
        }

        var map: [String: Record] = [:]
        for journal in journals.sorted(by: { $0.date < $1.date }) {
            for item in items(in: journal.body) where !item.text.isEmpty {
                var record = map[item.text] ?? Record(
                    text: item.text,
                    firstDate: journal.date,
                    lastDate: journal.date,
                    days: [],
                    done: item.done
                )
                record.days.insert(journal.date)
                record.lastDate = journal.date
                record.done = item.done
                map[item.text] = record
            }
        }

        return map.values
            .filter { !$0.done }
            .map { JournalTodo(text: $0.text, firstDate: $0.firstDate, lastDate: $0.lastDate, dayCount: $0.days.count) }
            .sorted { a, b in
                if a.lastDate != b.lastDate { return a.lastDate > b.lastDate }
                return a.text < b.text
            }
    }

    // MARK: - 行解析

    /// 解析 `[-*+] [ ] 文本`。与 `JournalCarry` 的规则一致：`]` 后必须有一个空白。
    private static func parse(_ line: String) -> (done: Bool, text: String)? {
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
