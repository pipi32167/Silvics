import Foundation
import Markdown

/// 日记待办融合：把上一篇日记里未完成的待办，按标题路径并进当天同名节点。
///
/// 只有解析用树（`swift-markdown`），写入是纯文本按行插入，绝不重新序列化整篇。
/// 理由：重新序列化会重写表格对齐、行内样式、围栏信息，git diff 也会整篇变红。
///
/// 规则见 `docs/日记编辑器边界用例.md` M 组与 issue #48：
///
/// - 归属：待办归它前面最近的标题路径（`["工作", "部署"]`），不是只看最后一级标题。
/// - 落点：目标节点所在段的最后一个非空行之后；段内全空就紧跟标题行。
/// - 判重：整篇按去首尾空白的文本比对，出现过就跳过（不看勾没勾）。
/// - 缺段：全路径与末级标题都不命中，就按层级在文末补标题链。
/// - 第一条标题之前的待办落到第一个标题所在段；一个标题都没有就追加到正文末尾。
/// - 带子块的待办整块搬，缩进与标记原样保留。
enum JournalMerge {

    /// 一条待搬的未完成待办。`lines` 是来源原文里的整块行（含子项），搬过去一个字符都不改。
    struct Carried: Equatable {
        /// 标题路径。空数组表示它写在第一个标题之前。
        var path: [String]
        /// 来源里最近那级标题的层级（`##` 是 2）。缺段补标题链时按它算层级。
        var level: Int
        /// 判重用的文本：去掉标记与首尾空白后的那一行内容。
        var text: String
        /// 原文整块行。
        var lines: [String]
    }

    /// 每段加了几条，给提示语用。
    struct Placement: Equatable {
        var section: String
        var count: Int
    }

    /// 融合结果。`added == 0` 表示一条都没加（没有未完成项，或已经全部在正文里）。
    struct Merge: Equatable {
        var body: String
        var added: Int
        var skipped: Int
        var placements: [Placement]

        /// `融合 2 条：生活 1、工作 1。` 没有新增时给空字符串。
        var statusText: String {
            guard added > 0 else { return "" }
            let detail = placements.map { "\($0.section) \($0.count)" }.joined(separator: "、")
            return detail.isEmpty ? "融合 \(added) 条。" : "融合 \(added) 条：\(detail)。"
        }
    }

    // MARK: - 读取来源

    /// 正文里全部未完成的待办，按出现顺序。围栏代码块里的不算（AST 天然排除）。
    static func openTodos(in body: String) -> [Carried] {
        let lines = body.components(separatedBy: "\n")
        return todoNodes(in: body)
            .filter { !$0.done }
            .compactMap { node in
                guard let text = todoText(fromLine: node.firstLine), !text.isEmpty else { return nil }
                let block = Array(lines[node.startLine...node.endLine])
                return Carried(path: node.path, level: node.level, text: text, lines: dedent(block))
            }
    }

    /// 正文里全部待办的文本（不管勾没勾），判重用。
    static func todoTexts(in body: String) -> Set<String> {
        var out = Set<String>()
        for node in todoNodes(in: body) {
            guard let text = todoText(fromLine: node.firstLine), !text.isEmpty else { continue }
            out.insert(text)
        }
        return out
    }

    // MARK: - 融合

    /// 把 `items` 并进 `body`。已存在的条目跳过，缺的段按层级补到文末。
    static func merge(into body: String, from items: [Carried]) -> Merge {
        guard !items.isEmpty else { return Merge(body: body, added: 0, skipped: 0, placements: []) }

        var lines = body.components(separatedBy: "\n")
        var existing = todoTexts(in: body)
        var added = 0
        var skipped = 0
        var placements: [Placement] = []
        var placementIndex: [String: Int] = [:]

        // 每插入一条就重建索引：段边界与行号都会变，重算比分片维护偏移更不容易错。
        // 日记几 KB、条目几十条，代价可以忽略。
        for item in items {
            if existing.contains(item.text) {
                skipped += 1
                continue
            }

            var index = SectionIndex(body: lines.joined(separator: "\n"))

            if item.path.isEmpty {
                // 第一条标题之前的待办：落到第一个标题所在段；一个标题都没有就追加到正文末尾。
                if let first = index.headings.first {
                    lines.insert(contentsOf: item.lines, at: first.insertAfter + 1)
                    added += 1
                    record(&placements, &placementIndex, section: first.title)
                } else {
                    lines.insert(contentsOf: item.lines, at: lastContentLine(in: lines) + 1)
                    added += 1
                    record(&placements, &placementIndex, section: "")
                }
                existing.insert(item.text)
                continue
            }

            if index.resolve(path: item.path) == nil {
                index.createChain(for: item.path, leafLevel: item.level, in: &lines)
                index = SectionIndex(body: lines.joined(separator: "\n"))
            }
            guard let target = index.resolve(path: item.path) else { continue }

            lines.insert(contentsOf: item.lines, at: target.insertAfter + 1)
            existing.insert(item.text)
            added += 1
            record(&placements, &placementIndex, section: target.title)
        }

        return Merge(
            body: lines.joined(separator: "\n"),
            added: added,
            skipped: skipped,
            placements: placements
        )
    }

    private static func record(
        _ placements: inout [Placement],
        _ index: inout [String: Int],
        section: String
    ) {
        if let at = index[section] {
            placements[at].count += 1
        } else {
            index[section] = placements.count
            placements.append(Placement(section: section, count: 1))
        }
    }

    /// 去掉整块共有的缩进。嵌在别的条目下、但父条目已经勾掉的待办会被提升成同级，
    /// 不去掉缩进就会带着原来的缩进插到上一条下面，结构悄悄变化。
    static func dedent(_ lines: [String]) -> [String] {
        guard let first = lines.first else { return lines }
        let indent = String(first.prefix { $0 == " " || $0 == "\t" })
        guard !indent.isEmpty else { return lines }
        return lines.map { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, line.hasPrefix(indent) else { return line }
            return String(line.dropFirst(indent.count))
        }
    }

    /// 最后一个非空行的行号。全空返回 -1。
    private static func lastContentLine(in lines: [String]) -> Int {
        var last = -1
        for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            last = i
        }
        return last
    }

    // MARK: - 标题索引

    /// 正文里的 `##` 分段索引。只认标题与行的关系，写入按行号切，不做列偏移计算。
    struct SectionIndex {
        struct Node {
            var path: [String]
            var title: String
            var level: Int
            var line: Int
            /// 段末行号（下一个同级或更高级标题之前）。
            var endLine: Int
            /// 段内最后一个非空行；段内全空时等于标题行。
            var insertAfter: Int
        }

        var headings: [Node] = []
        private var byKey: [String: Int] = [:]
        private var leafCount: [String: Int] = [:]
        private var byLeaf: [String: Int] = [:]

        init(body: String) {
            let raw = JournalMerge.headings(in: body)
            let total = body.components(separatedBy: "\n").count
            let lines = body.components(separatedBy: "\n")
            var nodes: [Node] = []
            for (i, heading) in raw.enumerated() {
                let next = raw[(i + 1)...].first { $0.level <= heading.level }
                let endLine = (next.map { $0.line - 1 } ?? (total - 1))
                var insertAfter = heading.line
                if endLine > heading.line {
                    for line in heading.line...endLine
                    where !lines[line].trimmingCharacters(in: .whitespaces).isEmpty {
                        insertAfter = line
                    }
                }
                nodes.append(Node(
                    path: heading.path,
                    title: heading.text,
                    level: heading.level,
                    line: heading.line,
                    endLine: max(heading.line, endLine),
                    insertAfter: insertAfter
                ))
            }
            headings = nodes
            for (i, node) in nodes.enumerated() {
                let key = Self.key(node.path)
                if byKey[key] == nil { byKey[key] = i }
                if let leaf = node.path.last {
                    leafCount[leaf, default: 0] += 1
                    if byLeaf[leaf] == nil { byLeaf[leaf] = i }
                }
            }
        }

        static func key(_ path: [String]) -> String { path.joined(separator: "\u{1}") }

        /// 全路径优先，最后一级标题唯一命中兜底。
        func resolve(path: [String]) -> Node? {
            if let i = byKey[Self.key(path)] { return headings[i] }
            guard let leaf = path.last, leafCount[leaf] == 1, let i = byLeaf[leaf] else { return nil }
            return headings[i]
        }

        /// 按来源层级在文末补标题链，缺哪级补哪级。同名节点已存在时不再补。
        ///
        /// `leafLevel` 是来源里最后一级标题的层级；路径中间几级按它往上推，
        /// 这样 `### 部署` 缺父级时会补成 `## 工作` + `### 部署`，不是 `# 工作`。
        func createChain(for path: [String], leafLevel: Int, in lines: inout [String]) {
            guard !path.isEmpty else { return }
            let leaf = max(1, min(6, leafLevel))
            var current = SectionIndex(body: lines.joined(separator: "\n"))
            for depth in 1...path.count {
                let prefix = Array(path.prefix(depth))
                if current.byKey[Self.key(prefix)] != nil { continue }
                let level = max(1, leaf - (path.count - depth))
                if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append("")
                }
                lines.append(String(repeating: "#", count: level) + " " + prefix[depth - 1])
                current = SectionIndex(body: lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - AST

    struct HeadingRecord {
        var level: Int
        /// 0-based 行号。
        var line: Int
        var text: String
        var path: [String]
    }

    /// 按出现顺序的标题。围栏代码块里的 `#` 不是标题（AST 天然排除）。
    static func headings(in body: String) -> [HeadingRecord] {
        var walker = StructureWalker()
        walker.visit(Document(parsing: body))
        return walker.headingRecords
    }

    struct TodoNode {
        var path: [String]
        var level: Int
        var done: Bool
        /// 0-based 起止行（含）。
        var startLine: Int
        var endLine: Int
        var firstLine: String
    }

    /// 按出现顺序的待办节点。`###` 子标题下的待办归自己的路径。
    static func todoNodes(in body: String) -> [TodoNode] {
        var walker = StructureWalker()
        walker.visit(Document(parsing: body))
        let lines = body.components(separatedBy: "\n")
        return walker.todoRecords.compactMap { record in
            guard lines.indices.contains(record.startLine) else { return nil }
            return TodoNode(
                path: record.path,
                level: record.level,
                done: record.done,
                startLine: record.startLine,
                endLine: min(record.endLine, lines.count - 1),
                firstLine: lines[record.startLine]
            )
        }
    }

    /// 一次遍历同时收标题与待办，顺带维护标题路径栈。
    private struct StructureWalker: MarkupWalker {
        struct RawTodo {
            var path: [String]
            var level: Int
            var done: Bool
            var startLine: Int
            var endLine: Int
        }

        var stack: [String] = []
        var levels: [Int] = []
        var headingRecords: [HeadingRecord] = []
        var todoRecords: [RawTodo] = []

        mutating func visitHeading(_ heading: Heading) {
            let level = max(1, heading.level)
            stack = Array(stack.prefix(level - 1))
            levels = Array(levels.prefix(level - 1))
            let text = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            stack.append(text)
            levels.append(level)
            headingRecords.append(HeadingRecord(
                level: level,
                line: max(0, (heading.range?.lowerBound.line ?? 1) - 1),
                text: text,
                path: stack
            ))
        }

        mutating func visitListItem(_ item: ListItem) {
            guard let checkbox = item.checkbox else {
                descendInto(item)
                return
            }
            let range = item.range
            let start = max(0, (range?.lowerBound.line ?? 1) - 1)
            var end = max(start, (range?.upperBound.line ?? 1) - 1)
            // 结束位置落在下一行行首时，内容其实止于上一行。
            if let upper = range?.upperBound, upper.column == 1, end > start { end -= 1 }
            todoRecords.append(RawTodo(
                path: stack,
                level: levels.last ?? 2,
                done: checkbox == .checked,
                startLine: start,
                endLine: end
            ))
            // 未完成的条目整块搬（含子项），不再单独记录子项，避免搬两遍。
            if checkbox != .unchecked { descendInto(item) }
        }
    }

    // MARK: - 行文本

    /// 解析 `[-*+] [ ] 文本` 或 `1. [ ] 文本`，返回条目文本（去首尾空白）。
    ///
    /// 与 `JournalTodos.parse` 口径一致：`]` 后面必须有一个空白，之后的文本原样保留。
    static func todoText(fromLine line: String) -> String? {
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" { rest = rest.dropFirst() }

        if let marker = rest.first, marker == "-" || marker == "*" || marker == "+" {
            rest = rest.dropFirst()
        } else if rest.first?.isNumber == true {
            while let c = rest.first, c.isNumber { rest = rest.dropFirst() }
            guard let punct = rest.first, punct == "." || punct == ")" else { return nil }
            rest = rest.dropFirst()
        } else {
            return nil
        }

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

        return String(rest).trimmingCharacters(in: .whitespaces)
    }
}
