import AppKit
import XCTest
@testable import Silvics

/// 代码高亮词法器（`CodeLexer`）与代码块区间（`MarkdownStyler.codeBlockRegions`）。
///
/// 编号与 `docs/日记编辑器边界用例.md` 的 1.5（H）与 1.6（L）节对齐。
/// 最强的约束是 H01：token 拼回去必须逐字符等于原文——高亮只描述区间，不改文本。
final class CodeLexerTests: XCTestCase {

    // MARK: - 工具

    /// 按区间把 token 拼回文本。
    private func joined(_ tokens: [CodeToken], in code: String) -> String {
        let ns = code as NSString
        return tokens.map { ns.substring(with: $0.range) }.joined()
    }

    /// `(文本, 类别)` 序列，方便断言具体切片。
    private func slices(_ tokens: [CodeToken], in code: String) -> [(String, CodeTokenKind)] {
        let ns = code as NSString
        return tokens.map { (ns.substring(with: $0.range), $0.kind) }
    }

    /// 覆盖 `text` 的那一个 token 的类别（找不到就 fail）。
    private func kind(
        of text: String,
        in code: String,
        language: String,
        line: UInt = #line
    ) -> CodeTokenKind? {
        let hit = slices(CodeLexer.lex(code, language: language), in: code).filter { $0.0 == text }
        XCTAssertFalse(hit.isEmpty, "没有文本为「\(text)」的 token", line: line)
        return hit.first?.1
    }

    /// 词法结果必须覆盖全文：首 token 从 0 开始、相邻、无重叠、末 token 到末尾。H01 / H13 共用。
    private func assertPartition(
        _ tokens: [CodeToken],
        in code: String,
        _ label: String,
        line: UInt = #line
    ) {
        XCTAssertEqual(joined(tokens, in: code), code, "\(label)：token 拼回原文必须逐字符相等", line: line)
        XCTAssertEqual(tokens.map(\.range.location).first ?? 0, 0, "\(label)：首个 token 必须从 0 开始", line: line)
        var cursor = 0
        for token in tokens {
            XCTAssertEqual(token.range.location, cursor, "\(label)：区间必须相邻且不重叠", line: line)
            XCTAssertGreaterThan(token.range.length, 0, "\(label)：不产出空 token", line: line)
            cursor = token.range.location + token.range.length
        }
        XCTAssertEqual(cursor, (code as NSString).length, "\(label)：末个 token 必须到原文末尾", line: line)
    }

    // MARK: - H01 每种语言 token 拼回原文

    private let swiftSample = """
    // 计数器
    let count = 42
    struct Box<T> {
        func add(_ a: Int) -> Int { return a + 0x1F }
        let name = "a // not comment"
    }
    """

    private let jsSample = """
    const url = "http://x/y"; // 注释
    function go(n) { return n * 1.5e-3; }
    class A extends B { get x() { return null; } }
    """

    private let pythonSample = """
    # 注释
    def add(a, b):
        s = "单行"
        return a + b
    if __name__ == "__main__":
        print(None, True)
    """

    private let jsonSample = """
    {"a": 1, "b": [true, null, 3.14], "s": "文本"}
    """

    private let bashSample = """
    #!/bin/sh
    echo $#
    count=$((1 + 2))
    # 注释
    echo "hi"
    """

    private let latexSample = """
    \\frac{a}{b} % 分式
    \\alpha + \\beta = 100
    """

    private let genericSample = """
    # hash comment
    let x = 1 /* 块
    注释 */
    const s = "a";
    """

    func testH01SwiftTokensRebuildOriginal() {
        assertPartition(CodeLexer.lex(swiftSample, language: "swift"), in: swiftSample, "swift")
    }

    func testH01JsTokensRebuildOriginal() {
        assertPartition(CodeLexer.lex(jsSample, language: "js"), in: jsSample, "js")
    }

    func testH01PythonTokensRebuildOriginal() {
        assertPartition(CodeLexer.lex(pythonSample, language: "python"), in: pythonSample, "python")
    }

    func testH01JsonTokensRebuildOriginal() {
        assertPartition(CodeLexer.lex(jsonSample, language: "json"), in: jsonSample, "json")
    }

    func testH01BashTokensRebuildOriginal() {
        assertPartition(CodeLexer.lex(bashSample, language: "bash"), in: bashSample, "bash")
    }

    func testH01LatexTokensRebuildOriginal() {
        assertPartition(CodeLexer.lex(latexSample, language: "latex"), in: latexSample, "latex")
    }

    func testH01GenericTokensRebuildOriginal() {
        // 空标记 = 通用词法
        assertPartition(CodeLexer.lex(genericSample, language: ""), in: genericSample, "generic")
    }

    /// 中文与 emoji 的 UTF-16 偏移也不能错位（注释里放中文、字符串里放 emoji）。
    func testH01WideCharactersKeepUTF16Offsets() {
        let code = "let s = \"🙂中文\" // 注释里有中文"
        assertPartition(CodeLexer.lex(code, language: "swift"), in: code, "wide")
    }

    // MARK: - H02 字符串里的 `//` 不算注释

    func testH02SlashesInsideStringAreNotComment() {
        let code = "let url = \"http://example.com\" // 真注释"
        let tokens = slices(CodeLexer.lex(code, language: "swift"), in: code)
        XCTAssertTrue(tokens.contains { $0.0 == "\"http://example.com\"" && $0.1 == .string })
        XCTAssertTrue(tokens.contains { $0.0 == "// 真注释" && $0.1 == .comment })
        // `http:` 那段不能被拆出来当注释
        XCTAssertFalse(tokens.contains { $0.0.contains("//example") && $0.1 == .comment })
    }

    // MARK: - H03 注释里的引号不开启字符串

    func testH03QuoteInsideCommentDoesNotOpenString() {
        let code = """
        // 这里的 " 只是注释里的引号
        let a = 1
        """
        let tokens = CodeLexer.lex(code, language: "swift")
        assertPartition(tokens, in: code, "H03")
        XCTAssertEqual(slices(tokens, in: code).first?.1, .comment)
        XCTAssertTrue(slices(tokens, in: code).filter { $0.1 == .string }.isEmpty, "注释里的引号不该产生字符串 token")
    }

    // MARK: - H04 未闭合块注释吃到块尾

    func testH04UnclosedBlockCommentStopsAtBlockEnd() {
        let code = """
        let a = 1
        /* 没闭合
        整段都是注释
        """
        let tokens = CodeLexer.lex(code, language: "swift")
        let list = slices(tokens, in: code)
        XCTAssertEqual(list.last?.1, .comment)
        XCTAssertEqual(list.last?.0, "/* 没闭合\n整段都是注释")
        assertPartition(tokens, in: code, "H04")
    }

    func testH04UnclosedBlockCommentDoesNotLeakToNextBlock() {
        let first = "/* 没闭合\n继续注释"
        let second = "let b = \"x\" // c"
        XCTAssertEqual(slices(CodeLexer.lex(first, language: "swift"), in: first).last?.1, .comment)
        // 第二次调用是全新扫描，第二个块完全不受影响
        let tokens = slices(CodeLexer.lex(second, language: "swift"), in: second)
        XCTAssertEqual(tokens.map(\.1), [.keyword, .plain, .string, .plain, .comment])
    }

    // MARK: - H05 Python 三引号跨行仍是一个 string token

    func testH05PythonTripleQuoteSpansLinesAsOneString() {
        let code = #"""
        def f():
            s = """第一行
        第二行"""
            return s
        """#
        let tokens = slices(CodeLexer.lex(code, language: "python"), in: code)
        let strings = tokens.filter { $0.1 == .string }
        XCTAssertEqual(strings.count, 1, "三引号整段只能是一个 string token")
        XCTAssertEqual(strings.first?.0, "\"\"\"第一行\n第二行\"\"\"")
        assertPartition(CodeLexer.lex(code, language: "python"), in: code, "H05")
    }

    func testH05UnclosedTripleQuoteStopsAtBlockEnd() {
        let code = "s = \"\"\"没有收口\n第二行"
        let tokens = CodeLexer.lex(code, language: "python")
        XCTAssertEqual(slices(tokens, in: code).last?.1, .string)
        assertPartition(tokens, in: code, "H05-unclosed")
    }

    // MARK: - H06 JS 模板字符串整体当 string

    func testH06JsTemplateStringIsOneString() {
        let code = "const t = `a ${b} // c\n第二行`;"
        let tokens = slices(CodeLexer.lex(code, language: "js"), in: code)
        let strings = tokens.filter { $0.1 == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual(strings.first?.0, "`a ${b} // c\n第二行`", "模板字符串内部不细分（已知取舍）")
        XCTAssertFalse(tokens.contains { $0.1 == .comment }, "模板字符串里的 `//` 不是注释")
    }

    // MARK: - H07 JSON 里的 `//` 不是注释

    func testH07JsonDoubleSlashIsNotComment() {
        let code = "{\"u\": \"//not-comment\"}"
        let tokens = slices(CodeLexer.lex(code, language: "json"), in: code)
        XCTAssertTrue(tokens.filter { $0.1 == .comment }.isEmpty, "JSON 没有行注释")
        XCTAssertTrue(tokens.contains { $0.0 == "\"//not-comment\"" && $0.1 == .string })
    }

    func testH07JsonHasNoBlockComment() {
        let code = "{\"a\": \"/* 只是字符串 */\"}"
        let tokens = slices(CodeLexer.lex(code, language: "json"), in: code)
        XCTAssertTrue(tokens.filter { $0.1 == .comment }.isEmpty, "JSON 没有块注释")
        XCTAssertTrue(tokens.contains { $0.0.contains("/* 只是字符串 */") && $0.1 == .string })
    }

    // MARK: - H08 bash 的 `#`

    func testH08BashShebangIsComment() {
        let code = "#!/bin/sh"
        let tokens = slices(CodeLexer.lex(code, language: "bash"), in: code)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.0, "#!/bin/sh")
        XCTAssertEqual(tokens.first?.1, .comment)
    }

    func testH08BashDollarHashIsNotComment() {
        let code = "echo $#args"
        let tokens = slices(CodeLexer.lex(code, language: "bash"), in: code)
        XCTAssertTrue(tokens.filter { $0.1 == .comment }.isEmpty, "`$#` 里的 `#` 不是注释起点")
    }

    func testH08BashIndentedCommentStillWorks() {
        let code = "    # 缩进后的注释"
        XCTAssertEqual(slices(CodeLexer.lex(code, language: "bash"), in: code).last?.1, .comment)
    }

    // MARK: - H09 / H10 未知语言与别名

    func testH09UnknownLanguageFallsBackToGeneric() {
        XCTAssertEqual(CodeLanguage.normalize("rust"), .generic)
        XCTAssertEqual(CodeLanguage.normalize("zig"), .generic)
        let code = "fn main() { // 注释\n    let s = \"x\";\n} /* 块 */"
        let tokens = CodeLexer.lex(code, language: "rust")
        assertPartition(tokens, in: code, "H09")
        XCTAssertTrue(slices(tokens, in: code).contains { $0.1 == .comment })
    }

    func testH10LanguageAliasesNormalize() {
        XCTAssertEqual(CodeLanguage.normalize("ts"), .js)
        XCTAssertEqual(CodeLanguage.normalize("typescript"), .js)
        XCTAssertEqual(CodeLanguage.normalize("jsx"), .js)
        XCTAssertEqual(CodeLanguage.normalize("tsx"), .js)
        XCTAssertEqual(CodeLanguage.normalize("sh"), .bash)
        XCTAssertEqual(CodeLanguage.normalize("shell"), .bash)
        XCTAssertEqual(CodeLanguage.normalize("zsh"), .bash)
        XCTAssertEqual(CodeLanguage.normalize("math"), .latex)
        XCTAssertEqual(CodeLanguage.normalize("tex"), .latex)
        XCTAssertEqual(CodeLanguage.normalize("katex"), .latex)
        XCTAssertEqual(CodeLanguage.normalize("py"), .python)
    }

    func testH10LanguageMarkerIsCaseAndSpaceInsensitive() {
        XCTAssertEqual(CodeLanguage.normalize("Swift"), .swift)
        XCTAssertEqual(CodeLanguage.normalize("  SWIFT  "), .swift)
        XCTAssertEqual(CodeLanguage.normalize("swift linenums"), .swift)
        XCTAssertEqual(CodeLanguage.normalize("JS"), .js)
        XCTAssertEqual(CodeLanguage.normalize("Math"), .latex)
        XCTAssertEqual(CodeLanguage.normalize(""), .generic)
    }

    // MARK: - H11 空代码块

    func testH11EmptyCodeBlockLexesToNothing() {
        XCTAssertEqual(CodeLexer.lex("", language: "swift"), [])
        XCTAssertEqual(CodeLexer.lex("", language: ""), [])
    }

    func testH11EmptyCodeBlockHasNoColorableRegion() {
        let doc = """
        ```swift
        ```
        """
        let spans = MarkdownStyler.analyze(doc)
        XCTAssertEqual(spans.codeBlocks.count, 1, "两行围栏仍然是一个代码块")
        XCTAssertTrue(MarkdownStyler.codeBlockRegions(in: doc, spans: spans).isEmpty, "没有内容行 → 没有上色区间")
    }

    // MARK: - H12 相邻代码块状态不串

    func testH12AdjacentCodeBlocksDoNotShareState() {
        let doc = """
        ```swift
        let a = "未收口
        ```
        ```python
        # 注释
        s = "x"
        ```
        """
        let spans = MarkdownStyler.analyze(doc)
        let regions = MarkdownStyler.codeBlockRegions(in: doc, spans: spans)
        XCTAssertEqual(regions.count, 2)
        let ns = doc as NSString
        XCTAssertEqual(regions[0].language, "swift")
        XCTAssertEqual(regions[1].language, "python")
        XCTAssertEqual(ns.substring(with: regions[1].contentRange), "# 注释\ns = \"x\"")

        // 第二块按 python 词法：`#` 是注释，`"x"` 是字符串（第一块的未闭合引号不该带过来）
        let tokens = slices(
            CodeLexer.lex(ns.substring(with: regions[1].contentRange), language: regions[1].language),
            in: ns.substring(with: regions[1].contentRange)
        )
        XCTAssertEqual(tokens.map(\.1), [.comment, .plain, .string])
    }

    // MARK: - H13 区间不越界、不重叠

    func testH13TokenRangesStayInsideBlockBounds() {
        let doc = """
        正文之前
        ```latex
        \\frac{1}{2} % 注释
        ```
        正文之后
        """
        let spans = MarkdownStyler.analyze(doc)
        let ns = doc as NSString
        let regions = MarkdownStyler.codeBlockRegions(in: doc, spans: spans)
        XCTAssertEqual(regions.count, 1)
        let region = regions[0]
        let code = ns.substring(with: region.contentRange)
        let tokens = CodeLexer.lex(code, language: region.language)
        var cursor = 0
        for token in tokens {
            XCTAssertEqual(token.range.location, cursor, "H13：相邻且不重叠")
            cursor = token.range.location + token.range.length
            let absolute = NSRange(location: region.contentRange.location + token.range.location, length: token.range.length)
            XCTAssertLessThanOrEqual(absolute.location + absolute.length, ns.length, "H13：不越界")
            XCTAssertGreaterThanOrEqual(absolute.location, region.contentRange.location, "H13：不碰到围栏行")
        }
        XCTAssertEqual(cursor, region.contentRange.length)
        // 围栏行本身不在内容区间里
        XCTAssertFalse(code.contains("```"))
    }

    func testH13FenceLinesAreExcludedFromContent() {
        let doc = """
        ```swift
        let a = 1
        let b = 2
        ```
        """
        let spans = MarkdownStyler.analyze(doc)
        XCTAssertEqual(spans.codeBlocks.count, 1)
        let regions = MarkdownStyler.codeBlockRegions(in: doc, spans: spans)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual((doc as NSString).substring(with: regions[0].contentRange), "let a = 1\nlet b = 2")
        XCTAssertEqual(regions[0].language, "swift")
    }

    func testH13EveryLanguageRegionKeepsFenceOut() {
        let doc = """
        ```js
        const a = 1;
        ```
        ```bash
        echo "x"
        ```
        """
        let spans = MarkdownStyler.analyze(doc)
        let ns = doc as NSString
        let regions = MarkdownStyler.codeBlockRegions(in: doc, spans: spans)
        XCTAssertEqual(regions.map(\.language), ["js", "bash"])
        XCTAssertEqual(regions.map { ns.substring(with: $0.contentRange) }, ["const a = 1;", "echo \"x\""])
    }

    /// 围栏行整行区间：首尾各一行，内容行不在里面。
    /// 渲染层靠这个只淡化围栏行，不再给它们加底色（灰块回归）。
    func testFenceLineRangesCoverOnlyFenceLines() {
        let doc = """
        正文
        ```swift
        let a = 1
        ```
        尾巴
        """
        let spans = MarkdownStyler.analyze(doc)
        let ns = doc as NSString
        let fences = MarkdownStyler.codeFenceLineRanges(in: doc, spans: spans)
        XCTAssertEqual(fences.count, 2)
        XCTAssertEqual(fences.map { ns.substring(with: $0) }, ["```swift", "```"])

        let regions = MarkdownStyler.codeBlockRegions(in: doc, spans: spans)
        XCTAssertEqual(regions.count, 1)
        for fence in fences {
            XCTAssertEqual(
                NSIntersectionRange(fence, regions[0].contentRange).length, 0,
                "围栏行不能与内容行重叠"
            )
        }
    }

    func testIndentedCodeBlockHasNoFenceLine() {
        let doc = """
        正文

            缩进代码
            第二行
        """
        let spans = MarkdownStyler.analyze(doc)
        XCTAssertEqual(spans.codeBlocks.count, 1)
        XCTAssertTrue(MarkdownStyler.codeFenceLineRanges(in: doc, spans: spans).isEmpty)
        XCTAssertEqual(MarkdownStyler.codeBlockRegions(in: doc, spans: spans).count, 1)
    }

    // MARK: - L01 / L02 公式块

    func testL01LatexCommandsAreKeywords() {
        let code = "\\frac{a}{b} + \\alpha"
        let tokens = slices(CodeLexer.lex(code, language: "latex"), in: code)
        XCTAssertEqual(tokens.first?.0, "\\frac")
        XCTAssertEqual(tokens.first?.1, .keyword)
        XCTAssertTrue(tokens.contains { $0.0 == "\\alpha" && $0.1 == .keyword })
        assertPartition(CodeLexer.lex(code, language: "latex"), in: code, "L01")
    }

    func testL02PercentIsLatexComment() {
        let code = "\\beta % 这里是注释"
        let tokens = slices(CodeLexer.lex(code, language: "latex"), in: code)
        XCTAssertEqual(tokens.last?.0, "% 这里是注释")
        XCTAssertEqual(tokens.last?.1, .comment)
    }

    func testL03LatexFenceIsRecognizedAsCodeBlock() {
        let doc = """
        ```latex
        \\frac{1}{2}
        ```
        """
        let spans = MarkdownStyler.analyze(doc)
        let regions = MarkdownStyler.codeBlockRegions(in: doc, spans: spans)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].language, "latex")
    }

    func testLatexAlsoAcceptsMathAlias() {
        let doc = """
        ```Math
        \\alpha
        ```
        """
        let spans = MarkdownStyler.analyze(doc)
        let regions = MarkdownStyler.codeBlockRegions(in: doc, spans: spans)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(CodeLanguage.normalize(regions[0].language), .latex, "别名 `math` 要在渲染层也归一")
    }

    // MARK: - 其他实现细节

    func testFunctionNameBeforeParenIsFunction() {
        let code = "print(1) value = 2"
        let tokens = slices(CodeLexer.lex(code, language: "python"), in: code)
        XCTAssertEqual(tokens.first?.1, .function)
        XCTAssertTrue(tokens.contains { $0.0.contains("value") && $0.1 == .plain })
    }

    func testNumbersCoverHexDecimalAndExponent() {
        let code = "a 0x1F 3 2.5 1e-3 1E+4"
        let numbers = slices(CodeLexer.lex(code, language: "swift"), in: code)
            .filter { $0.1 == .number }
            .map(\.0)
        XCTAssertEqual(numbers, ["0x1F", "3", "2.5", "1e-3", "1E+4"])
    }

    func testPlainTokensAreMerged() {
        let code = "a -> b"
        let tokens = slices(CodeLexer.lex(code, language: "swift"), in: code)
        XCTAssertEqual(tokens.map(\.0), ["a -> b"], "同类相邻 token 合并，减少属性 run")
    }

    func testUnquotedIdentifierWithDollarSignStaysOneToken() {
        let code = "const $el = $(x);"
        let tokens = slices(CodeLexer.lex(code, language: "js"), in: code)
        XCTAssertTrue(tokens.contains { $0.0.contains("$el") && $0.1 == .plain })
        XCTAssertTrue(
            tokens.contains { $0.0 == "$" && $0.1 == .function },
            "`$(` 仍然认得出函数名"
        )
    }

    /// 上色只改属性：刷完字色后文本逐字符不变，`plain` 保留正文色。
    func testH13PaintingChangesAttributesNotCharacters() {
        let code = "let a = 1 // c"
        let storage = NSTextStorage(string: code, attributes: Theme.baseAttributes())
        for token in CodeLexer.lex(code, language: "swift") {
            guard let color = Theme.tokenColor(token.kind) else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: token.range)
        }
        XCTAssertEqual(storage.string, code, "上色不改字符")
        let ns = storage.string as NSString
        func color(_ text: String) -> NSColor? {
            let range = ns.range(of: text)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(color("let"), Theme.tokenKeyword)
        XCTAssertEqual(color("1"), Theme.tokenNumber)
        XCTAssertEqual(color("// c"), Theme.tokenComment)
        XCTAssertEqual(color("a"), Theme.text, "标识符保留正文色")
    }

    // MARK: - 性能

    /// H 组性能门槛：300 行的块，一次词法 + 一次属性上色要在 50 ms 内。
    func testPerformance300LinesUnder50Milliseconds() {
        let block = """
        import Foundation

        struct Counter {
            let hits = 0x1F
            var total: Double = 1.5e-3

            func bump(_ step: Int) -> Int {
                let label = "step \\(step) // 不是注释"
                // 这一行是注释
                return hits + total.hashValue + step
            }
        }

        """
        var code = ""
        var lineCount = 0
        while lineCount < 300 {
            code += block
            lineCount = code.split(separator: "\n", omittingEmptySubsequences: false).count
        }
        XCTAssertGreaterThanOrEqual(lineCount, 300, "样本必须 ≥ 300 行")

        // 真的往 NSTextStorage 上刷属性：这才是渲染路径上要花的时间（不是只算 token 个数）
        func runOnce() -> (tokens: [CodeToken], painted: Int, milliseconds: Double) {
            let start = Date()
            let tokens = CodeLexer.lex(code, language: "swift")
            let storage = NSTextStorage(string: code, attributes: Theme.baseAttributes())
            var painted = 0
            storage.beginEditing()
            for token in tokens {
                guard let color = Theme.tokenColor(token.kind) else { continue }
                storage.addAttribute(.foregroundColor, value: color, range: token.range)
                painted += 1
            }
            storage.endEditing()
            return (tokens, painted, Date().timeIntervalSince(start) * 1000)
        }

        _ = runOnce() // 预热（首次要走静态表初始化）
        var best = Double.greatestFiniteMagnitude
        var tokens: [CodeToken] = []
        var painted = 0
        for _ in 0..<5 {
            let result = runOnce()
            tokens = result.tokens
            painted = result.painted
            best = min(best, result.milliseconds)
        }
        print("[perf] 门槛 50 ms；\(lineCount) 行、\(tokens.count) 个 token、\(painted) 次上色，实测 \(String(format: "%.2f", best)) ms")
        XCTAssertLessThan(best, 50, "300 行词法 + 上色超过 50 ms：\(best) ms")
        XCTAssertEqual(joined(tokens, in: code), code, "性能样本也不能改文本")
    }
}
