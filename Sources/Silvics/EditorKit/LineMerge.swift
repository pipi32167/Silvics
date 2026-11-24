import Foundation

/// 行级三方合并（diff3）。
///
/// 只做一种判断：把两边对 base 的改动合到一起。
/// 同一段被两边都改了，就报冲突，由调用方决定（保留本地 + 留档，不写冲突标记）。
///
/// 为什么不写冲突标记：正文是 Markdown，`<<<<<<<` 会污染内容，
/// 也会让 `[[ ]]` 与 `#标签` 的扫描结果错乱。
enum LineMerge {

    struct Result: Equatable {
        var text: String
        /// 0 表示干净合并。大于 0 时 `text` 仍是「保留本地」的结果，不可直接采信。
        var conflictCount: Int
        var isClean: Bool { conflictCount == 0 }
    }

    /// 行数乘积上限。超过就放弃自动合并，交人工。
    static let maxWork = 400_000

    static func merge(base: String, ours: String, theirs: String) -> Result? {
        if ours == theirs { return Result(text: ours, conflictCount: 0) }
        if base == ours { return Result(text: theirs, conflictCount: 0) }
        if base == theirs { return Result(text: ours, conflictCount: 0) }

        let b = split(base)
        let o = split(ours)
        let t = split(theirs)
        guard b.count * max(o.count, t.count) <= maxWork else { return nil }

        let oursHunks = hunks(base: b, other: o)
        let theirsHunks = hunks(base: b, other: t)

        var out: [String] = []
        var conflicts = 0
        var i = 0
        var ai = 0
        var ti = 0

        while true {
            let hasA = ai < oursHunks.count
            let hasT = ti < theirsHunks.count
            if !hasA && !hasT {
                if i < b.count { out.append(contentsOf: b[i...]) }
                break
            }

            let a = hasA ? oursHunks[ai] : nil
            let t2 = hasT ? theirsHunks[ti] : nil

            // 起点相同：两边都在同一位置改
            if let a, let t2, a.start == t2.start {
                if i < a.start { out.append(contentsOf: b[i..<a.start]) }
                if a.replacement == t2.replacement {
                    out.append(contentsOf: a.replacement)
                } else {
                    conflicts += 1
                    out.append(contentsOf: a.replacement)
                }
                i = max(a.end, t2.end)
                ai += 1
                ti += 1
                continue
            }

            // 起点不同但区间重叠：也是冲突
            if let a, let t2, a.start < t2.end && t2.start < a.end {
                let head = min(a.start, t2.start)
                if i < head { out.append(contentsOf: b[i..<head]) }
                conflicts += 1
                out.append(contentsOf: a.start <= t2.start ? a.replacement : t2.replacement)
                i = max(a.end, t2.end)
                ai += 1
                ti += 1
                continue
            }

            // 已被消费掉一半的区间：保守报冲突
            if let a, a.start < i {
                conflicts += 1
                ai += 1
                continue
            }
            if let t2, t2.start < i {
                conflicts += 1
                ti += 1
                continue
            }

            if let a, a.start <= (t2?.start ?? Int.max) {
                if i < a.start { out.append(contentsOf: b[i..<a.start]) }
                out.append(contentsOf: a.replacement)
                i = a.end
                ai += 1
            } else if let t2 {
                if i < t2.start { out.append(contentsOf: b[i..<t2.start]) }
                out.append(contentsOf: t2.replacement)
                i = t2.end
                ti += 1
            } else {
                break
            }
        }

        return Result(text: out.joined(separator: "\n"), conflictCount: conflicts)
    }

    // MARK: - 内部

    /// base 上被改动的一段：`[start, end)` 换成 `replacement`。
    private struct Hunk {
        var start: Int
        var end: Int
        var replacement: [String]
    }

    private static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// 把 `other` 相对 `base` 的改动切成若干段。
    private static func hunks(base: [String], other: [String]) -> [Hunk] {
        let pairs = lcsMatches(base, other)
        var result: [Hunk] = []
        var bi = 0
        var oi = 0
        for (mb, mo) in pairs + [(base.count, other.count)] {
            if mb > bi || mo > oi {
                result.append(Hunk(start: bi, end: mb, replacement: Array(other[oi..<mo])))
            }
            bi = mb + 1
            oi = mo + 1
        }
        return result
    }

    /// 最长公共子序列的匹配对，按顺序返回。
    private static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
