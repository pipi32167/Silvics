import Foundation

/// 标签策略：优先用已有标签，新标签每次最多两个。
///
/// 候选集 = 剪藏标签 ∪ 概念笔记标签。模型只能从这里挑，或提出新标签；
/// 本地再做归一化、去重、限流。模型输出不直接落库。
enum ClipTagPolicy {

    static let maxNewTags = 2
    static let minLength = 2
    static let maxLength = 12

    struct Outcome: Equatable {
        var tags: [String]
        /// 给用户看的提示。没有问题时为空。
        var warnings: [String]
    }

    /// 清洗一个标签。非法字符删掉；长度不合规返回 nil。
    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        text = text.filter { ch in
            if ch == "_" || ch == "-" || ch == "/" { return true }
            return ch.isLetter || ch.isNumber
        }
        guard text.count >= minLength, text.count <= maxLength else { return nil }
        return text
    }

    /// 归一化键：大小写、全半角、空白、英文单复数。
    static func key(_ raw: String) -> String {
        let base = TextNormalizer.key(sanitize(raw) ?? raw)
        guard base.count > 3,
              base.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) })
        else { return base }
        return base.hasSuffix("s") ? String(base.dropLast()) : base
    }

    /// 应用模型给出的标签。
    ///
    /// - Parameters:
    ///   - proposed: 模型原始输出。
    ///   - existing: 已有标签（剪藏 + 概念笔记），用于归一化比对。
    ///   - target: 目标个数，少于这个数不自动补。
    static func apply(proposed: [String], existing: [String], target: Int) -> Outcome {
        var byKey: [String: String] = [:]
        for name in existing {
            guard let clean = sanitize(name) else { continue }
            let k = key(clean)
            if byKey[k] == nil { byKey[k] = clean }
        }

        var result: [String] = []
        var seen = Set<String>()
        var newCount = 0
        var dropped = 0

        for raw in proposed {
            guard let clean = sanitize(raw) else { dropped += 1; continue }
            let k = key(clean)
            guard seen.insert(k).inserted else { continue }
            if let existingName = byKey[k] {
                result.append(existingName)
                continue
            }
            guard newCount < maxNewTags else { dropped += 1; continue }
            byKey[k] = clean
            result.append(clean)
            newCount += 1
        }

        var warnings: [String] = []
        if dropped > 0 {
            warnings.append("已丢弃 \(dropped) 个不合规或超量的标签")
        }
        if result.count < 3 {
            warnings.append("模型只给出 \(result.count) 个标签，可手动补")
        }
        if result.count > max(target, 3) {
            result = Array(result.prefix(max(target, 3)))
        }
        return Outcome(tags: result, warnings: warnings)
    }
}
