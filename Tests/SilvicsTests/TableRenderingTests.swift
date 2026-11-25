import AppKit
import XCTest
@testable import Silvics

/// 表格识别、宽度度量、kern 补齐与对齐。
///
/// 两层：
/// - 识别、显示宽度、列起点、kern 公式都是纯函数，直接给期望值；
/// - 对齐结论用真的 TextKit 2 文本视图量 `firstRect`，不看属性表推算。
///
/// 对齐判据来自 `/tmp/tables2/metrics.txt`：四行的第 2/3/4 个 `|` 的 x 偏差 ≤ 1pt。
final class TableRenderingTests: XCTestCase {

    private let table = """
    | 项目 | 状态 | 备注 |
    | --- | :---: | --- |
    | 排版 | 未实现 | 三列 |
    | 对齐 | 待验证 | 等宽 |
    """

    // MARK: - 工具

    private func blocks(_ text: String) -> [TableBlock] {
        TableLayout.blocks(in: text)
    }

    private func cellTexts(_ block: TableBlock, in text: String) -> [[String]] {
        let ns = text as NSString
        return block.rows.map { row in row.cells.map { ns.substring(with: $0) } }
    }

    private func paragraph(_ text: String, containing location: Int) -> NSRange {
        (text as NSString).paragraphRange(for: NSRange(location: location, length: 0))
    }

    private func isBold(_ font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    /// 造一个真的 TextKit 2 文本视图，把表格属性写进去。
    private func makeRenderedTable(_ text: String, caretRow: Int? = nil) -> (EditorTextView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 28, height: 24)
        scrollView.documentView = textView
        window.contentView = scrollView

        let storage = NSMutableAttributedString(string: text, attributes: Theme.baseAttributes())
        let caret = caretRow.flatMap { row -> NSRange? in
            guard let block = blocks(text).first, row < block.rows.count else { return nil }
            return paragraph(text, containing: block.rows[row].contentRange.location)
        }
        for block in blocks(text) {
            for item in TableLayout.attributes(for: block, in: text, caretParagraph: caret) {
                let clamped = NSRange(
                    location: item.range.location,
                    length: min(item.range.length, storage.length - item.range.location)
                )
                guard clamped.length > 0 else { continue }
                storage.addAttributes(item.attributes, range: clamped)
            }
        }
        textView.textStorage?.setAttributedString(storage)
        if let manager = textView.textLayoutManager {
            manager.ensureLayout(for: manager.documentRange)
        }
        window.layoutIfNeeded()
        textView.layoutSubtreeIfNeeded()
        return (textView, window)
    }

    /// 某字符在视图坐标里的 x（相对容器左缘）。
    private func x(of location: Int, in textView: EditorTextView, window: NSWindow) -> CGFloat {
        var actual = NSRange()
        let rect = textView.firstRect(
            forCharacterRange: NSRange(location: location, length: 1),
            actualRange: &actual
        )
        let inView = textView.convert(window.convertFromScreen(rect), from: nil)
        return inView.minX - textView.textContainerOrigin.x
    }

    // MARK: - 识别

    func testRecognizesStandardThreeColumnTable() {
        let found = blocks(table)
        XCTAssertEqual(found.count, 1)
        guard let block = found.first else { return }
        XCTAssertEqual(block.columnCount, 3)
        XCTAssertEqual(block.rows.count, 4)
        XCTAssertTrue(block.rows[0].isHeader)
        XCTAssertTrue(block.rows[1].isDelimiter)
        XCTAssertFalse(block.rows[2].isDelimiter)
        XCTAssertEqual(block.rows.map(\.pipes.count), [4, 4, 4, 4])

        let ns = table as NSString
        XCTAssertEqual(ns.substring(with: block.rows[0].cells[0]), " 项目 ")
        XCTAssertEqual(ns.substring(with: block.rows[2].cells[1]), " 未实现 ")
        XCTAssertEqual(ns.substring(with: block.rows[3].cells[2]), " 等宽 ")
        // 整块区间正好是四行原文（不含末尾换行）。
        XCTAssertEqual(ns.substring(with: block.range), table)
    }

    func testRecognizesAlignmentColonsInDelimiter() {
        XCTAssertTrue(TableLayout.isDelimiterCell(" --- "))
        XCTAssertTrue(TableLayout.isDelimiterCell(" :---: "))
        XCTAssertTrue(TableLayout.isDelimiterCell("---:"))
        // GFM 的分隔格是 `:?-+:?`，一个横线也算。
        XCTAssertTrue(TableLayout.isDelimiterCell(" -- "))
        XCTAssertFalse(TableLayout.isDelimiterCell(" -+- "))
        XCTAssertFalse(TableLayout.isDelimiterCell(" :  : "))
        XCTAssertFalse(TableLayout.isDelimiterCell(" "))
    }

    func testMissingDelimiterIsNotTable() {
        let text = """
        | 项目 | 状态 | 备注 |
        | 排版 | 未实现 | 三列 |
        | 对齐 | 待验证 | 等宽 |
        """
        XCTAssertTrue(blocks(text).isEmpty)
    }

    func testInconsistentColumnCountIsNotTable() {
        let text = """
        | 项目 | 状态 | 备注 |
        | --- | --- | --- |
        | 排版 | 未实现 |
        | 对齐 | 待验证 | 等宽 |
        """
        XCTAssertTrue(blocks(text).isEmpty)
    }

    func testPipesInsideFencedCodeBlockAreNotTable() {
        let text = """
        正文。

        ```text
        | 项目 | 状态 | 备注 |
        | --- | --- | --- |
        | 排版 | 未实现 | 三列 |
        ```

        | 项目 | 状态 | 备注 |
        | --- | --- | --- |
        | 排版 | 未实现 | 三列 |
        """
        let found = blocks(text)
        XCTAssertEqual(found.count, 1)
        guard let block = found.first else { return }
        XCTAssertEqual(block.rows.count, 3)
        // 代码块里的那段 pipe 不在块区间内。
        XCTAssertGreaterThan(block.range.location, (text as NSString).range(of: "```text").location)
    }

    func testSingleColumnTableNeedsTwoPipesPerLine() {
        let text = """
        | 甲 |
        | --- |
        | 乙 |
        """
        let found = blocks(text)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.columnCount, 1)
    }

    func testLineWithoutLeadingPipeIsNotTable() {
        let text = """
        项目 | 状态 | 备注
        --- | --- | ---
        排版 | 未实现 | 三列
        """
        XCTAssertTrue(blocks(text).isEmpty)
    }

    // MARK: - 显示宽度

    func testDisplayWidthCountsCJKAsTwoAndASCIIAsOne() {
        XCTAssertEqual(TableLayout.displayWidth("ab"), 2)
        XCTAssertEqual(TableLayout.displayWidth("项目"), 4)
        XCTAssertEqual(TableLayout.displayWidth(" 项目 "), 6)
        XCTAssertEqual(TableLayout.displayWidth(" 排版 ab "), 9)
        // 全角冒号也是 2。
        XCTAssertEqual(TableLayout.displayWidth("状态：ok"), 8)
        XCTAssertEqual(TableLayout.displayWidth(""), 0)
    }

    func testColumnTargetsUseDisplayWidthOfWidestCell() {
        let unit: CGFloat = 10
        let rowsOfCells = [[" 项目 ", " 状态 "], [" a ", " bb "]]
        let targets = TableLayout.columnTargets(rowsOfCells, unit: unit)
        // 第 1 列最宽 6 个显示宽度（" 项目 "），第 2 列最宽 6（" 状态 "），各加 2 格留白。
        XCTAssertEqual(targets[0], 80, accuracy: 0.001)
        XCTAssertEqual(targets[1], 80, accuracy: 0.001)
    }

    func testColumnTargetIsNeverNarrowerThanNaturalCell() {
        // 按字符数算列宽时目标会比实测窄（中文 4 个字符 = 4 格，实际 2 格字宽 × 2 字），
        // pipe 会被挤进文字里。这条用例盯住「目标宽不小于该格的自然宽」。
        let unit = TableLayout.unitWidth()
        let text = "| 项目 | 状态 | 备注 |\n| --- | --- | --- |\n| 排版 | 未实现啊 | 三列 |"
        guard let block = blocks(text).first else { return XCTFail("没识别到表格") }
        let cells = cellTexts(block, in: text)
        let targets = TableLayout.columnTargets(cells, unit: unit)
        for (row, rowCells) in cells.enumerated() {
            let font = row == 0 ? Theme.tableHeaderFont : Theme.tableFont
            for (column, cell) in rowCells.enumerated() {
                let measured = TableLayout.measure(cell, font)
                XCTAssertGreaterThanOrEqual(targets[column] + 0.5, measured,
                                            "第 \(row) 行第 \(column) 列的目标宽比实测窄")
            }
        }
    }

    // MARK: - kern

    func testKernFillsCellToTargetWidth() {
        let unit = TableLayout.unitWidth()
        let rowsOfCells = [[" 项目 ", " 状态 ", " 备注 "], [" 排版 ", " 未实现 ", " 三列 "]]
        let targets = TableLayout.columnTargets(rowsOfCells, unit: unit)
        for (row, cells) in rowsOfCells.enumerated() {
            let font = row == 0 ? Theme.tableHeaderFont : Theme.tableFont
            for (column, text) in cells.enumerated() {
                let measured = TableLayout.measure(text, font)
                let kern = TableLayout.kern(measured: measured, target: targets[column])
                XCTAssertEqual(measured + kern, targets[column], accuracy: 0.5,
                               "第 \(row) 行第 \(column) 列 kern 补齐后应等于目标宽")
            }
        }
    }

    func testKernTargetIsLastNonSpaceCharacter() {
        guard let block = blocks(table).first else { return XCTFail("没识别到表格") }
        let ns = table as NSString
        let cell = block.rows[2].cells[1]                 // " 未实现 "
        guard let index = TableLayout.kernTargetIndex(cell: cell, in: ns) else {
            return XCTFail("没有承接 kern 的字符")
        }
        // 尾随空格上不加 kern（TextKit 量出来只有一半位移）；指向最后一个实字「现」。
        XCTAssertEqual(ns.substring(with: NSRange(location: index, length: 1)), "现")

        // 全是空格的格子退回单元格首字符，不返回 nil。
        XCTAssertEqual(TableLayout.kernTargetIndex(cell: NSRange(location: 1, length: 3), in: "|   |" as NSString), 1)
    }

    func testColumnStartsMatchEveryRow() {
        guard let block = blocks(table).first else { return XCTFail("没识别到表格") }
        let cells = cellTexts(block, in: table)
        let unit = TableLayout.unitWidth()
        let targets = TableLayout.columnTargets(cells, unit: unit)
        let expected = TableLayout.pipeStarts(cellTargets: targets, unit: unit)
        XCTAssertEqual(expected.count, 4)

        for (row, rowCells) in cells.enumerated() {
            let font = block.rows[row].isHeader ? Theme.tableHeaderFont : Theme.tableFont
            let starts = TableLayout.rowPipeStarts(
                cells: rowCells,
                cellTargets: targets,
                font: font,
                unit: unit
            )
            XCTAssertEqual(starts.count, expected.count)
            for (actual, target) in zip(starts, expected) {
                XCTAssertEqual(actual, target, accuracy: 0.5,
                               "第 \(row) 行的 pipe 应落在列起点上")
            }
        }
    }

    // MARK: - 渲染属性

    func testHeaderRowIsBoldAndUnderlined() {
        guard let block = blocks(table).first else { return XCTFail("没识别到表格") }
        let items = TableLayout.attributes(for: block, in: table, caretParagraph: nil)
        let header = paragraph(table, containing: block.rows[0].contentRange.location)
        guard let row = items.first(where: { $0.range == header && $0.attributes[.paragraphStyle] != nil })
        else { return XCTFail("表头行没有整行属性") }

        guard let font = row.attributes[.font] as? NSFont else { return XCTFail("表头没有字体") }
        XCTAssertEqual(font.pointSize, Theme.tableFontSize)
        XCTAssertTrue(isBold(font))
        XCTAssertTrue(font.isFixedPitch)
        XCTAssertEqual(row.attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNotNil(row.attributes[.underlineColor])

        // 数据行不加粗、不加下划线。
        let body = paragraph(table, containing: block.rows[2].contentRange.location)
        guard let bodyRow = items.first(where: { $0.range == body && $0.attributes[.paragraphStyle] != nil })
        else { return XCTFail("数据行没有整行属性") }
        guard let bodyFont = bodyRow.attributes[.font] as? NSFont else { return XCTFail("数据行没有字体") }
        XCTAssertFalse(isBold(bodyFont))
        XCTAssertNil(bodyRow.attributes[.underlineStyle])
    }

    func testDelimiterRowFadesWithoutChangingText() {
        guard let block = blocks(table).first else { return XCTFail("没识别到表格") }
        let items = TableLayout.attributes(for: block, in: table, caretParagraph: nil)
        let delimiter = paragraph(table, containing: block.rows[1].contentRange.location)
        guard let row = items.first(where: { $0.range == delimiter && $0.attributes[.paragraphStyle] != nil })
        else { return XCTFail("分隔行没有整行属性") }
        XCTAssertTrue((row.attributes[.foregroundColor] as AnyObject) === Theme.tableDelimiter)

        // 应用全部属性后正文一个字符都不变。
        let storage = NSMutableAttributedString(string: table, attributes: Theme.baseAttributes())
        for item in items {
            guard item.range.location + item.range.length <= storage.length else { continue }
            storage.addAttributes(item.attributes, range: item.range)
        }
        XCTAssertEqual(storage.string, table)
    }

    func testCaretRowKeepsNaturalSpacingAndOthersStayAligned() {
        guard let block = blocks(table).first else { return XCTFail("没识别到表格") }
        let caret = paragraph(table, containing: block.rows[2].contentRange.location)
        let items = TableLayout.attributes(for: block, in: table, caretParagraph: caret)

        func kernItems(in cellRange: NSRange) -> Int {
            items.filter { item in
                item.range.length == 1
                    && item.attributes[.kern] != nil
                    && item.range.location >= cellRange.location
                    && item.range.location < cellRange.location + cellRange.length
            }.count
        }
        // 光标行：一格都不补 kern（露源码）。
        for cell in block.rows[2].cells {
            XCTAssertEqual(kernItems(in: cell), 0)
        }
        // 其他行照旧补齐。
        for cell in block.rows[3].cells {
            XCTAssertEqual(kernItems(in: cell), 1)
        }
    }

    // MARK: - 真实排版：pipe 对齐

    func testRenderedTablePipesAlignWithinOnePoint() {
        guard let block = blocks(table).first else { return XCTFail("没识别到表格") }
        let (textView, window) = makeRenderedTable(table)
        defer { window.orderOut(nil) }

        var rowsX: [[CGFloat]] = []
        for row in block.rows {
            rowsX.append(row.pipes.map { x(of: $0.location, in: textView, window: window) })
        }
        XCTAssertEqual(rowsX.count, 4)

        for column in 1..<block.columnCount {
            let xs = rowsX.compactMap { $0.count > column ? $0[column] : nil }
            guard let lo = xs.min(), let hi = xs.max() else { return XCTFail("第 \(column) 列量不到 pipe") }
            XCTAssertLessThanOrEqual(hi - lo, 1.0,
                                     "第 \(column + 1) 个 | 的 x 偏差 \(hi - lo) pt 超过 1pt（x∈[\(lo), \(hi)]）")
        }
    }

    func testRenderedCaretRowIsNotAligned() {
        guard let block = blocks(table).first else { return XCTFail("没识别到表格") }
        // 光标放第 3 行：该行的 pipe 回到等宽自然位置，与其它行明显不齐。
        let (textView, window) = makeRenderedTable(table, caretRow: 2)
        defer { window.orderOut(nil) }

        let target = block.columnCount - 1
        let others = block.rows.enumerated()
            .filter { $0.offset != 2 }
            .compactMap { x(of: $0.element.pipes[target].location, in: textView, window: window) }
        let caretRow = x(of: block.rows[2].pipes[target].location, in: textView, window: window)
        guard let lo = others.min(), let hi = others.max() else { return XCTFail("量不到 pipe") }
        XCTAssertLessThanOrEqual(hi - lo, 1.0)
        XCTAssertGreaterThan(abs(caretRow - lo), 1.0, "光标行应回到源码的自然位置")
    }
}
