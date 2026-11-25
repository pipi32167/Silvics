import AppKit
import Foundation

/// 一个 Markdown 表格块的识别结果。**只描述区间，不改正文一个字符。**
///
/// 表格不引入任何新结构：`note.body` 里就是那几行 pipe 文本，
/// 这里算出「哪几行是表、每个单元格在哪」，渲染期靠字体 + kern 把 pipe 对齐。
/// 与 `NSTextTable` 的差别：后者要把一行摊成一格一段落，等于改写正文，已排除。
struct TableBlock: Equatable {
    struct Row: Equatable {
        /// 整行区间（行首到行尾，不含换行）。
        var contentRange: NSRange
        /// 每个 `|` 的区间（长度 1）。
        var pipes: [NSRange]
        /// pipe 之间的单元格区间（含两侧空格，不含 pipe）。
        var cells: [NSRange]
        /// 第一行是表头。
        var isHeader: Bool
        /// 分隔行：`| --- | :---: |`。
        var isDelimiter: Bool
    }

    var rows: [Row]
    /// 列数（= 每行 pipe 数 − 1）。
    var columnCount: Int
    /// 整块区间：第一行行首到最后一行行尾（不含末尾换行）。
    var range: NSRange
}

/// 表格的识别、宽度度量与渲染属性。
///
/// 对齐策略（实测见 `/tmp/tables2/metrics.txt`）：等宽 13pt + 按显示宽度补齐 kern。
/// 三件事必须同时成立，少一件就偏：
/// 1. 列宽按**显示宽度**算（CJK 记 2、ASCII 记 1），不是字符数；
/// 2. 每格的目标宽 = (该列最宽显示宽度 + 2) × 一个 ASCII 字宽；
/// 3. kern 只加在**该格最后一个非空格字符**上，值 = 目标宽 − 实测宽，不乘 2、不给整格加。
///
/// kern 加在尾随空格上时 TextKit 的 `firstRect` 只报一半位移；加在整格上则重复累加。
/// 这两处就是上一版算错的地方，`TableRenderingTests` 里各有一条用例盯着。
enum TableLayout {

    /// 表头行下方的淡分隔线、以及分隔行的淡色都由 `Theme` 提供，这里只管布局。

    // MARK: - 识别

    /// 找出正文里全部表格块。代码块（围栏内）里的 pipe 不算。
    ///
    /// 判定：连续的 pipe 行成一块，要求
    /// - 至少 2 行（表头 + 分隔行）；
    /// - 第 2 行是分隔行（`---` / `:---:`）；
    /// - 所有行列数一致。
    /// 任何一条不满足，整块都不算表格，原样当正文显示。
    static func blocks(in text: String) -> [TableBlock] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var out: [TableBlock] = []
        var run: [TableBlock.Row] = []
        var fence: (character: Character, count: Int)?

        func flush() {
            defer { run.removeAll() }
            guard run.count >= 2 else { return }
            let columns = run[0].cells.count
            guard columns >= 1, run[1].isDelimiter else { return }
            guard run.allSatisfy({ $0.cells.count == columns }) else { return }
            let start = run[0].contentRange.location
            let last = run[run.count - 1].contentRange
            out.append(TableBlock(
                rows: run,
                columnCount: columns,
                range: NSRange(location: start, length: last.location + last.length - start)
            ))
        }

        var cursor = 0
        while cursor < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            var end = lineRange.location + lineRange.length
            while end > lineRange.location {
                let ch = ns.character(at: end - 1)
                if ch == 0x0A || ch == 0x0D { end -= 1 } else { break }
            }
            let content = NSRange(location: lineRange.location, length: end - lineRange.location)
            let line = ns.substring(with: content)

            // 围栏状态：块内的 pipe 不参与识别（与 `MarkdownStyler.scanLineMarkers` 同一套规则）。
            var fenceLine = false
            if let open = fenceRun(line) {
                if let current = fence {
                    if open.character == current.character, open.count >= current.count {
                        fence = nil
                        fenceLine = true
                    }
                } else {
                    fence = open
                    fenceLine = true
                }
            }

            if fenceLine || fence != nil {
                flush()
            } else if var row = parseRow(line, contentRange: content) {
                row.isHeader = run.isEmpty
                run.append(row)
            } else {
                flush()
            }

            if lineRange.length == 0 { break }
            cursor = lineRange.location + lineRange.length
        }
        flush()
        return out
    }

    /// 行首（允许缩进）连续 ≥3 个反引号或波浪号。
    private static func fenceRun(_ line: String) -> (character: Character, count: Int)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let count = rest.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return (first, count)
    }

    private static let pipeUnit = UInt16(UInt8(ascii: "|"))

    /// 一行 pipe 文本 → 行内区间。首尾必须是 `|`（前后允许空白）。
    private static func parseRow(_ line: String, contentRange: NSRange) -> TableBlock.Row? {
        let ns = line as NSString
        var pipeIndices: [Int] = []
        for index in 0..<ns.length where ns.character(at: index) == pipeUnit {
            pipeIndices.append(index)
        }
        guard pipeIndices.count >= 2,
              let first = pipeIndices.first,
              let last = pipeIndices.last,
              isBlank(ns, 0..<first),
              isBlank(ns, (last + 1)..<ns.length) else { return nil }

        var relative: [NSRange] = []
        for k in 0..<(pipeIndices.count - 1) {
            let start = pipeIndices[k] + 1
            relative.append(NSRange(location: start, length: pipeIndices[k + 1] - start))
        }
        let delimiter = relative.allSatisfy { isDelimiterCell(ns.substring(with: $0)) }
        return TableBlock.Row(
            contentRange: contentRange,
            pipes: pipeIndices.map { NSRange(location: contentRange.location + $0, length: 1) },
            cells: relative.map { NSRange(location: contentRange.location + $0.location, length: $0.length) },
            isHeader: false,
            isDelimiter: delimiter
        )
    }

    private static func isBlank(_ ns: NSString, _ range: Range<Int>) -> Bool {
        for index in range {
            let ch = ns.character(at: index)
            if ch != 0x20 && ch != 0x09 { return false }
        }
        return true
    }

    /// `---` / `:---` / `---:` / `:---:`（两侧空白允许）。
    static func isDelimiterCell(_ text: String) -> Bool {
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        guard !body.isEmpty else { return false }
        if body.first == ":" { body = body.dropFirst() }
        if body.last == ":" { body = body.dropLast() }
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    // MARK: - 显示宽度

    /// 一个字符占几个 ASCII 字宽：CJK / 全角 / emoji 记 2，其余记 1。
    ///
    /// 这是「列宽」的唯一依据。按 `count` 算会把 `项目` 当 2 个字符，
    /// 于是目标宽比实际窄一倍，kern 也就补错一倍（上一版的第一个错误）。
    static func displayWidth(_ text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars {
            width += isWide(scalar.value) ? 2 : 1
        }
        return width
    }

    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F000...0x1F2FF, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    // MARK: - 度量

    /// 一段文本在指定字体下的排版宽度。
    static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 一个 ASCII 字宽（等宽字体下即「0」的宽度）。目标宽都以它为单位。
    static func unitWidth(font: NSFont = Theme.tableFont) -> CGFloat {
        measure("0", font)
    }

    /// 每列的目标宽：该列最宽显示宽度 + 两侧各一格留白。
    ///
    /// 单元格文本本身就带源码里的两侧空格（`| 项目 |` → `" 项目 "`），
    /// 所以这里再加 2 个显示宽度单位，让 pipe 与文字之间留一口气。
    static func columnTargets(_ rowsOfCells: [[String]], unit: CGFloat) -> [CGFloat] {
        guard let first = rowsOfCells.first else { return [] }
        var widest = [Int](repeating: 0, count: first.count)
        for cells in rowsOfCells where cells.count == widest.count {
            for (column, text) in cells.enumerated() {
                widest[column] = max(widest[column], displayWidth(text))
            }
        }
        return widest.map { CGFloat($0 + 2) * unit }
    }

    /// 让一格文本的总宽等于目标宽所需的 kern：`目标宽 − 实测宽`。
    ///
    /// 只加一次、只加在这一个字符上。加满整格或乘 2 都会把 pipe 推过头。
    static func kern(measured: CGFloat, target: CGFloat) -> CGFloat {
        target - measured
    }

    // MARK: - 列起点（纯函数，不依赖 UI）

    /// 各 pipe 相对行首的 x：`0, t0+u, t0+u+t1+u, …`。
    static func pipeStarts(cellTargets: [CGFloat], unit: CGFloat) -> [CGFloat] {
        var x: CGFloat = 0
        var out: [CGFloat] = []
        for target in cellTargets {
            out.append(x)
            x += target + unit
        }
        out.append(x)
        return out
    }

    /// 一行按「实测宽 + kern」累加出来的 pipe x。
    ///
    /// 与 `pipeStarts` 一致是渲染对齐的充要条件；对不上说明 kern 公式或字宽取值错了。
    static func rowPipeStarts(
        cells: [String],
        cellTargets: [CGFloat],
        font: NSFont,
        unit: CGFloat
    ) -> [CGFloat] {
        var x: CGFloat = 0
        var out: [CGFloat] = [0]
        for (column, text) in cells.enumerated() where column < cellTargets.count {
            let measured = measure(text, font)
            x += measured + kern(measured: measured, target: cellTargets[column]) + unit
            out.append(x)
        }
        return out
    }

    /// 该单元格里承接 kern 的字符：最后一个非空格字符（全是空格时取最后一个字符）。
    ///
    /// 加在尾随空格上时 TextKit 的 `firstRect` 只报一半位移，验收量不准；加在实字上才准。
    static func kernTargetIndex(cell: NSRange, in ns: NSString) -> Int? {
        guard cell.length > 0, cell.location >= 0,
              cell.location + cell.length <= ns.length else { return nil }
        var index = cell.location + cell.length - 1
        while index > cell.location {
            let ch = ns.character(at: index)
            if ch != 0x20 && ch != 0x09 { return index }
            index -= 1
        }
        return index
    }

    // MARK: - 渲染属性

    /// 表格一块要写的全部属性（按顺序应用，后者覆盖前者）。
    ///
    /// 只写属性，不动字符：所有区间都在原文范围内，长度不变。
    /// - 整行：等宽 13pt、表格段落样式、正文色；表头加粗 + 淡下划线；
    /// - 每格末字符：kern = 目标宽 − 实测宽（光标所在行不加，露源码）；
    /// - pipe：次级色；分隔行整体淡到 40%（光标所在行恢复可读色）。
    static func attributes(
        for block: TableBlock,
        in text: String,
        caretParagraph: NSRange?
    ) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
        let ns = text as NSString
        guard !block.rows.isEmpty else { return [] }
        let unit = unitWidth()
        let cellsOfRows = block.rows.map { row in
            row.cells.map { ns.substring(with: $0) }
        }
        let targets = columnTargets(cellsOfRows, unit: unit)

        var out: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        for (index, row) in block.rows.enumerated() {
            let isHeader = row.isHeader
            let font = isHeader ? Theme.tableHeaderFont : Theme.tableFont
            let inCaret = overlaps(row.contentRange, caretParagraph)
            let paragraph = ns.paragraphRange(for: NSRange(location: row.contentRange.location, length: 0))
            let faded = row.isDelimiter && !inCaret

            var rowAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: faded ? Theme.tableDelimiter : Theme.text,
                .paragraphStyle: Theme.tableParagraph(
                    first: index == 0,
                    last: index == block.rows.count - 1
                ),
                // 先清零：光标移进 / 移出这一行时，旧的 kern 必须被清掉。
                .kern: 0,
            ]
            if isHeader {
                rowAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                rowAttributes[.underlineColor] = Theme.tableHeaderRule
            }
            out.append((paragraph, rowAttributes))

            if !inCaret {
                for (column, cell) in row.cells.enumerated() where column < targets.count {
                    let measured = measure(cellsOfRows[index][column], font)
                    let value = kern(measured: measured, target: targets[column])
                    guard let target = kernTargetIndex(cell: cell, in: ns) else { continue }
                    out.append((NSRange(location: target, length: 1), [.kern: value]))
                }
            }

            let pipeColor = faded ? Theme.tableDelimiter : Theme.tablePipe
            for pipe in row.pipes {
                out.append((pipe, [.foregroundColor: pipeColor]))
            }
        }
        return out
    }

    private static func overlaps(_ range: NSRange, _ other: NSRange?) -> Bool {
        guard let other, other.length > 0, range.length > 0 else { return false }
        return range.location < other.location + other.length
            && other.location < range.location + range.length
    }
}
