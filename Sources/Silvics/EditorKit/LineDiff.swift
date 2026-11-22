import Foundation

/// 行级 diff。给「批量转换前先看 diff」用。
///
/// 只需要能回答「哪几行变了」。不追求最小编辑脚本，
/// 也不做字符级着色：预览里把整行标出来就够了。
enum LineDiff {

    /// 一行变更。`oldLine == nil` 表示新增行，`newLine == nil` 表示删除行。
    struct Change: Equatable {
        var oldLine: String?
        var newLine: String?
    }

    static func changes(old: String, new: String) -> [Change] {
        guard old != new else { return [] }

        let oldLines = lines(old)
        let newLines = lines(new)

        // 去掉公共前缀与后缀，中间才做 LCS。
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddle = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let newMiddle = Array(newLines[prefix..<(newLines.count - suffix)])
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else { return [] }

        // 太大就不算 LCS，直接整块替换。
        guard oldMiddle.count * newMiddle.count <= 250_000 else {
            return [Change(oldLine: oldMiddle.first, newLine: newMiddle.first)]
        }

        var changes: [Change] = []
        for step in lcsSteps(oldMiddle, newMiddle) {
            switch step {
            case .equal(let oldIndex, _):
                _ = oldIndex
            case .delete(let oldIndex):
                changes.append(Change(oldLine: oldMiddle[oldIndex], newLine: nil))
            case .insert(let newIndex):
                changes.append(Change(oldLine: nil, newLine: newMiddle[newIndex]))
            }
        }

        // 相邻的一删一增合并成一行「改」。
        var merged: [Change] = []
        var index = 0
        while index < changes.count {
            if index + 1 < changes.count,
               changes[index].newLine == nil, changes[index + 1].oldLine == nil {
                merged.append(Change(
                    oldLine: changes[index].oldLine,
                    newLine: changes[index + 1].newLine
                ))
                index += 2
            } else {
                merged.append(changes[index])
                index += 1
            }
        }
        return merged
    }

    private enum Step {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    private static func lcsSteps(_ a: [String], _ b: [String]) -> [Step] {
        let n = a.count, m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var steps: [Step] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                steps.append(.equal(i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                steps.append(.delete(i))
                i += 1
            } else {
                steps.append(.insert(j))
                j += 1
            }
        }
        while i < n { steps.append(.delete(i)); i += 1 }
        while j < m { steps.append(.insert(j)); j += 1 }
        return steps
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }
}
