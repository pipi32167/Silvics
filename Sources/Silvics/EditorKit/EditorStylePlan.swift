import Foundation

/// 一篇正文的样式计划：解析结果 + 行首标记 + 表格块 + 围栏行。
///
/// 为什么要有这一层（issue #50）：
/// 剪藏长文（十几万字）切换时，`restyle` 会对整篇做一次 Markdown 解析、一次逐行扫描、
/// 一次表格识别，全部在主线程同步跑完，这就是用户感到的「卡一下」。
/// 同一篇正文在「切走再切回」「只读 ↔ 编辑」时会被反复重算，
/// 所以按正文原文缓存这份计划，命中时只做属性写入。
///
/// 缓存只存区间与纯值，不存 `NSAttributedString`：正文一改就整份失效，没有增量合并的风险。
enum EditorStylePlan {

    struct Plan {
        var spans: EditorSpans
        var scan: LineScan
        var tables: [TableBlock]
        var fenceLines: [NSRange]
        /// 这次是命中缓存（true）还是重新算的（false）。取证与性能报告用。
        var fromCache: Bool = false
    }

    /// 缓存条目数。剪藏通常在相邻几篇之间来回切，3 条够用；长文也占不了多少内存（只有区间）。
    private static let limit = 3

    private final class Box {
        let key: String
        let plan: Plan
        init(key: String, plan: Plan) { self.key = key; self.plan = plan }
    }

    private static var entries: [Box] = []

    /// 取（或算）一篇正文的样式计划。命中缓存的判据是**整篇原文相等**，不做哈希，避免碰撞。
    static func plan(for text: String) -> Plan {
        if let hit = entries.first(where: { $0.key == text }) {
            var plan = hit.plan
            plan.fromCache = true
            return plan
        }
        var plan = build(text)
        plan.fromCache = false
        entries.insert(Box(key: text, plan: plan), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        return plan
    }

    /// 清空缓存。外观变了要重算属性，但宽高、区间与外观无关，这里只在测试里用。
    static func reset() { entries.removeAll() }

    private static func build(_ text: String) -> Plan {
        let scan = MarkdownStyler.scan(text)
        let spans = MarkdownStyler.analyze(text)
        return Plan(
            spans: spans,
            scan: scan,
            tables: MarkdownStyler.tableBlocks(in: text),
            fenceLines: MarkdownStyler.codeFenceLineRanges(in: text, spans: spans)
        )
    }
}
