import Foundation

/// 正文里可用于匹配的一类字符串：笔记标题或笔记别名。
///
/// 只携带扫描需要的信息。`EditorKit` 不依赖 `Core`，所以这里不带 `NoteMention` 类型。
struct MentionPattern: Equatable {
    /// 命中后要连到的笔记 id。
    var targetId: String
    /// 展示用的名字（原始标题或别名原文）。
    var displayName: String
    /// 这条模式来自标题还是别名。
    var kind: MentionPatternKind
}

enum MentionPatternKind: String, Equatable, Sendable {
    case exact
    case alias
}

/// 一次命中。
struct MentionHit: Equatable {
    /// 对应 `MentionScanner(patterns:)` 里 `patterns` 的下标。
    var patternIndex: Int
    /// 命中片段在原文中的区间。单位是 UTF-16，可直接喂给 `NSTextStorage`。
    var range: NSRange
}

/// 编辑区要画的一条提及：区间 + 目标标题。
struct MentionDecoration: Equatable {
    var range: NSRange
    var title: String
}

/// 未链接提及扫描器：Aho–Corasick 多模式匹配。
///
/// 为什么不用朴素匹配：设计文档 8.4 实测，1003 个标题扫 805 字正文，
/// 朴素 `String.range(of:)` 要 214 ms，Aho–Corasick 只要 0.099 ms。
///
/// 实现要点（照设计文档 8.4）：
/// 1. 按 Unicode 标量建转移表，键用 `UInt32`，中文标量直接当键。
/// 2. 归一化在插入模式时做，扫描正文时逐字符同样归一化。
/// 3. `out` 数组沿 fail 链合并，保证重叠命中全部报出。
/// 4. 命中只记结束位置，用 `end - 模式长度` 反推起点。
struct MentionScanner {

    /// 自动机节点。
    private struct Node {
        var next: [UInt32: Int] = [:]
        var fail: Int = 0
        var out: [Int] = []
    }

    let patterns: [MentionPattern]

    private var nodes: [Node] = []
    /// 每条模式归一化后的标量序列长度。
    private var patternLengths: [Int] = []
    /// 保留下来的模式下标（被停用词与长度门槛滤掉的不参与扫描）。
    private var activePatterns: [Int] = []

    // MARK: - 构建

    /// - Parameters:
    ///   - patterns: 标题与别名。为空时扫描结果恒为空。
    init(patterns: [MentionPattern]) {
        self.patterns = patterns
        var nodes: [Node] = [Node()]

        var lengths: [Int] = []
        var active: [Int] = []

        for (index, pattern) in patterns.enumerated() {
            let scalars = MentionText.normalizeScalars(pattern.displayName)
            lengths.append(scalars.count)
            guard MentionGate.isEligiblePattern(pattern.displayName) else { continue }
            guard !scalars.isEmpty else { continue }

            var state = 0
            for scalar in scalars {
                if let next = nodes[state].next[scalar] {
                    state = next
                } else {
                    nodes.append(Node())
                    let newIndex = nodes.count - 1
                    nodes[state].next[scalar] = newIndex
                    state = newIndex
                }
            }
            nodes[state].out.append(index)
            active.append(index)
        }

        // 建 fail 链与 out 合并。BFS 保证父节点先处理。
        var queue: [Int] = []
        for (_, child) in nodes[0].next {
            queue.append(child)          // 根的孩子 fail 已经默认 0
        }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for (scalar, child) in nodes[current].next {
                var fallback = nodes[current].fail
                while fallback != 0 && nodes[fallback].next[scalar] == nil {
                    fallback = nodes[fallback].fail
                }
                if let target = nodes[fallback].next[scalar], target != child {
                    nodes[child].fail = target
                } else {
                    nodes[child].fail = 0
                }
                nodes[child].out.append(contentsOf: nodes[nodes[child].fail].out)
                queue.append(child)
            }
        }

        self.nodes = nodes
        self.patternLengths = lengths
        self.activePatterns = active
    }

    /// 自动机节点数。用于测试断言规模。
    var nodeCount: Int { nodes.count }

    // MARK: - 扫描

    /// 扫描正文，返回未链接的提及。
    ///
    /// - Parameters:
    ///   - text: 笔记正文。
    ///   - excluding: 不参与匹配的区间（代码块、行内代码、已有的 `[[ ]]`）。
    ///   - maxPerTarget: 同一目标在单篇笔记内的上报上限。
    func scan(_ text: String, excluding: [NSRange] = [], maxPerTarget: Int = 20) -> [MentionHit] {
        guard !activePatterns.isEmpty, !text.isEmpty else { return [] }

        let run = MentionText.normalize(text)
        guard !run.scalars.isEmpty else { return [] }

        var hits: [MentionHit] = []
        var perTarget: [String: Int] = [:]
        var state = 0

        for i in run.scalars.indices {
            let scalar = run.scalars[i]
            while state != 0 && nodes[state].next[scalar] == nil {
                state = nodes[state].fail
            }
            state = nodes[state].next[scalar] ?? 0
            guard !nodes[state].out.isEmpty else { continue }

            let endNormalized = i + 1
            for patternIndex in nodes[state].out {
                let length = patternLengths[patternIndex]
                let startNormalized = endNormalized - length
                guard startNormalized >= 0 else { continue }

                let startUTF16 = run.utf16Start[startNormalized]
                let lastScalarIndex = endNormalized - 1
                let endUTF16 = run.utf16Start[lastScalarIndex] + run.utf16Length[lastScalarIndex]
                let range = NSRange(location: startUTF16, length: endUTF16 - startUTF16)
                guard range.length > 0 else { continue }
                guard !Self.overlaps(range, excluding) else { continue }

                let pattern = patterns[patternIndex]
                guard !MentionGate.isStopWord(pattern.displayName) else { continue }

                let used = perTarget[pattern.targetId, default: 0]
                guard used < maxPerTarget else { continue }
                perTarget[pattern.targetId] = used + 1

                hits.append(MentionHit(patternIndex: patternIndex, range: range))
            }
        }

        return hits.sorted { $0.range.location < $1.range.location }
    }

    private static func overlaps(_ range: NSRange, _ excluded: [NSRange]) -> Bool {
        for ex in excluded where ex.length > 0 {
            if NSIntersectionRange(range, ex).length > 0 { return true }
        }
        return false
    }
}

// MARK: - 归一化

/// 逐字符归一化 + UTF-16 偏移映射。
///
/// 归一化必须逐字符做，因为一个字符小写后可能变成多个标量（例如 `İ` → `i̇`）。
/// 记录每个归一化标量所属原文的 UTF-16 起点与长度，命中后能精确还原区间。
enum MentionText {

    struct NormalizedRun {
        var scalars: [UInt32] = []
        /// 每个标量对应的原文 UTF-16 起点。
        var utf16Start: [Int] = []
        /// 每个标量所属原文字符的 UTF-16 长度。
        var utf16Length: [Int] = []
    }

    /// 全角 ASCII 转半角、全角空格转空格、小写。
    static func mapScalar(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        if value >= 0xFF01 && value <= 0xFF5E { return value - 0xFEE0 }
        if value == 0x3000 { return 0x20 }
        return value
    }

    static func normalize(_ text: String) -> NormalizedRun {
        var out = NormalizedRun()
        out.scalars.reserveCapacity(text.utf16.count)
        out.utf16Start.reserveCapacity(text.utf16.count)
        out.utf16Length.reserveCapacity(text.utf16.count)

        var utf16 = 0
        for character in text {
            let length = character.utf16.count
            let lowered = String(character).lowercased()
            var emitted = false
            for scalar in lowered.unicodeScalars {
                out.scalars.append(mapScalar(scalar))
                out.utf16Start.append(utf16)
                out.utf16Length.append(length)
                emitted = true
            }
            if !emitted, let scalar = character.unicodeScalars.first {
                out.scalars.append(mapScalar(scalar))
                out.utf16Start.append(utf16)
                out.utf16Length.append(length)
            }
            utf16 += length
        }
        return out
    }

    static func normalizeScalars(_ text: String) -> [UInt32] {
        normalize(text).scalars
    }

    /// 归一化后的字符串。停用词比对用它，避免编辑器层依赖 `Core` 的 `TextNormalizer`。
    static func normalizedString(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for value in normalizeScalars(text) {
            if let scalar = Unicode.Scalar(value) { view.append(scalar) }
        }
        return String(view)
    }
}

// MARK: - 门槛

/// 中文子串匹配的三条门槛（设计文档 3.3）。
enum MentionGate {

    /// 门槛 1：片段长度。中文不少于 4 个汉字；英文不少于 2 个词。
    ///
    /// 两条补充：
    /// - 中英混写的术语（如 `GRDB 迁移`）只要有 2 个汉字就算合格。
    /// - 单个拉丁词长度不少于 8 个字符也算合格。理由：`Zettelkasten` 就是一个词，
    ///   按「2 个词」直接滤掉会漏掉真提及。
    static func isEligiblePattern(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let cjkCount = trimmed.unicodeScalars.filter { isCJK($0) }.count
        if cjkCount >= 4 { return true }

        let hasLatin = trimmed.unicodeScalars.contains { isLatin($0) }
        guard hasLatin else { return false }   // 纯中文但不到 4 个字，多半是噪音

        if cjkCount >= 2 { return true }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        return words.count >= 2 || trimmed.count >= 8
    }

    /// 门槛 2：停用词。
    static func isStopWord(_ name: String) -> Bool {
        StopWords.contains(MentionText.normalizedString(name))
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,   // 基本区
             0x3400...0x4DBF,   // 扩展 A
             0xF900...0xFAFF,   // 兼容汉字
             0x3040...0x30FF,   // 日文假名
             0xAC00...0xD7AF:   // 韩文
            return true
        default:
            return false
        }
    }

    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return true
        default:
            return false
        }
    }
}
