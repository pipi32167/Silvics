import XCTest
@testable import Silvics

final class MentionScannerTests: XCTestCase {

    private func makeScanner(_ names: [String], kind: MentionPatternKind = .exact) -> (MentionScanner, [MentionPattern]) {
        let patterns = names.enumerated().map { index, name in
            MentionPattern(targetId: "t\(index)", displayName: name, kind: kind)
        }
        return (MentionScanner(patterns: patterns), patterns)
    }

    private func matchedTexts(_ hits: [MentionHit], _ patterns: [MentionPattern], in text: String) -> [String] {
        let ns = text as NSString
        return hits.map { ns.substring(with: $0.range) }
    }

    // MARK: - 基本命中

    func testBasicMatch() {
        let (scanner, patterns) = makeScanner(["遗忘曲线决定长期留存"])
        let text = "集中突击短期有效，但遗忘曲线决定长期留存。"
        let hits = scanner.scan(text)
        XCTAssertEqual(matchedTexts(hits, patterns, in: text), ["遗忘曲线决定长期留存"])
    }

    /// 重叠命中必须全部报出：`out` 沿 fail 链合并的回归测试。
    func testOverlappingPatternsAllReported() {
        let (scanner, patterns) = makeScanner(["间隔重复", "间隔重复优于集中突击"])
        let text = "结论是间隔重复优于集中突击。"
        let hits = scanner.scan(text)
        XCTAssertEqual(matchedTexts(hits, patterns, in: text).sorted(), ["间隔重复", "间隔重复优于集中突击"])
    }

    /// 同一处文本被两个不同目标命中时也要全部报出。
    func testTwoTargetsSameText() {
        let patterns = [
            MentionPattern(targetId: "a", displayName: "最小可行产品", kind: .exact),
            MentionPattern(targetId: "b", displayName: "最小可行产品", kind: .alias),
        ]
        let scanner = MentionScanner(patterns: patterns)
        let hits = scanner.scan("先做最小可行产品。")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.patternIndex)), [0, 1])
    }

    // MARK: - 归一化

    func testCaseAndFullWidthInsensitive() {
        let (scanner, _) = makeScanner(["GRDB 迁移"])
        XCTAssertEqual(scanner.scan("用 grdb 迁移").count, 1)
        XCTAssertEqual(scanner.scan("用 ＧＲＤＢ　迁移").count, 1)
    }

    /// 归一化后长度会变的位置（`İ` 小写变成 `i` + `组合点`）之前的偏移不能把后续区间带偏。
    func testOffsetStaysCorrectAfterLengthChangingCharacter() {
        let (scanner, _) = makeScanner(["istanbul 计划"])
        let text = "İ 之后的 istanbul 计划 执行"
        let hits = scanner.scan(text)
        XCTAssertEqual(hits.count, 1, "命中数应为 1")
        let piece = (text as NSString).substring(with: hits[0].range)
        XCTAssertEqual(piece, "istanbul 计划")
    }

    /// UTF-16 区间必须精确。中文前置字符不能让区间偏移。
    func testUTF16RangeAccurate() {
        let (scanner, _) = makeScanner(["稀疏重复优于集中突击"])
        let text = "前言：结论是稀疏重复优于集中突击，理由见下文。"
        let hits = scanner.scan(text)
        XCTAssertEqual(hits.count, 1)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: hits[0].range), "稀疏重复优于集中突击")
        XCTAssertEqual(hits[0].range.location, (text as NSString).range(of: "稀疏重复").location)
    }

    // MARK: - 门槛

    func testShortCJKPatternRejected() {
        let (scanner, _) = makeScanner(["遗忘"])
        XCTAssertTrue(scanner.scan("遗忘曲线决定长期留存").isEmpty)
    }

    func testStopWordRejected() {
        XCTAssertTrue(MentionGate.isStopWord("笔记"))
        XCTAssertTrue(MentionGate.isStopWord("同时"))
        XCTAssertFalse(MentionGate.isStopWord("稀疏重复优于集中突击"))
    }

    func testLatinTwoWordsAccepted() {
        let (scanner, _) = makeScanner(["zettelkasten 方法"])
        XCTAssertEqual(scanner.scan("用 Zettelkasten 方法 记笔记").count, 1)
    }

    func testSingleLongLatinWordAccepted() {
        let (scanner, _) = makeScanner(["zettelkasten"])
        XCTAssertEqual(scanner.scan("用 Zettelkasten 记笔记").count, 1)
    }

    // MARK: - 排除区间

    func testExcludedRangesSkipped() {
        let (scanner, _) = makeScanner(["稀疏重复优于集中突击"])
        let text = "正文写了稀疏重复优于集中突击。\n\n```\n稀疏重复优于集中突击\n```"
        let all = scanner.scan(text)
        XCTAssertEqual(all.count, 2)

        let codeRange = (text as NSString).range(of: "稀疏重复优于集中突击\n```")
        let filtered = scanner.scan(text, excluding: [codeRange])
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].range.location, (text as NSString).range(of: "稀疏重复优于集中突击").location)
    }

    func testNoMatchWhenEverythingExcluded() {
        let (scanner, _) = makeScanner(["稀疏重复优于集中突击"])
        let text = "稀疏重复优于集中突击"
        let hits = scanner.scan(text, excluding: [NSRange(location: 0, length: (text as NSString).length)])
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - 上限

    func testPerTargetCap() {
        let (scanner, _) = makeScanner(["稀疏重复优于集中突击"])
        let text = Array(repeating: "稀疏重复优于集中突击。", count: 25).joined()
        XCTAssertEqual(scanner.scan(text).count, 20)
    }

    func testCapIsPerTarget() {
        let (scanner, _) = makeScanner(["稀疏重复优于集中突击", "遗忘曲线决定长期留存"])
        let text = Array(repeating: "稀疏重复优于集中突击。", count: 25).joined()
            + Array(repeating: "遗忘曲线决定长期留存。", count: 25).joined()
        let hits = scanner.scan(text)
        let counts = Dictionary(grouping: hits, by: { scanner.patterns[$0.patternIndex].targetId })
            .mapValues(\.count)
        XCTAssertEqual(counts["t0"], 20)
        XCTAssertEqual(counts["t1"], 20)
    }

    // MARK: - 性能

    /// 1000 条标题扫 805 字正文。
    ///
    /// 预算来自设计文档 8.4：release 0.099 ms，验收线 1 ms。
    /// Debug 构建无优化，预算放宽到 5 ms；Release 构建按 1 ms 卡。
    func testScanPerformanceWithThousandTitles() {
        let body = """
        集中突击可以短期记住更多，但遗忘曲线决定了长期留存。因此稀疏重复优于集中突击。
        间隔重复能对抗遗忘，但间隔的确定要依赖记忆强度。主动回忆比被动重读有效。
        写作是最有效的思考方式，因为写作强迫你把模糊的理解变成明确的句子。
        理解需要费力参与，费力参与意味着提取练习，提取练习又反过来强化记忆。
        常绿笔记要求标题写成断言句，断言句才能在别处当作自然语言使用。
        """

        var names: [String] = []
        for i in 0..<1000 {
            names.append("测试概念标题第\(i)号关于记忆与写作的关系")
        }
        // 塞入真实标题，保证有命中
        names[0] = "遗忘曲线决定长期留存"
        names[1] = "稀疏重复优于集中突击"
        names[2] = "写作是最有效的思考方式"

        let patterns = names.enumerated().map { index, name in
            MentionPattern(targetId: "t\(index)", displayName: name, kind: .exact)
        }

        let buildStart = CFAbsoluteTimeGetCurrent()
        let scanner = MentionScanner(patterns: patterns)
        let buildMs = (CFAbsoluteTimeGetCurrent() - buildStart) * 1000

        // 预热
        _ = scanner.scan(body)

        let rounds = 20
        let start = CFAbsoluteTimeGetCurrent()
        var hitCount = 0
        for _ in 0..<rounds {
            hitCount += scanner.scan(body).count
        }
        let averageMs = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(rounds)

        print(String(format: "[MentionScanner] build=%.3f ms scan=%.3f ms nodes=%d hits=%d",
                     buildMs, averageMs, scanner.nodeCount, hitCount / rounds))

        XCTAssertGreaterThan(hitCount, 0, "应当命中至少一条")
        #if DEBUG
        XCTAssertLessThan(buildMs, 40, "Debug 构建自动机构建预算 40 ms（release 实测 2.2 ms）")
        XCTAssertLessThan(averageMs, 5, "Debug 构建扫描预算 5 ms")
        #else
        XCTAssertLessThan(buildMs, 10, "Release 构建自动机构建预算 10 ms")
        XCTAssertLessThan(averageMs, 1, "Release 构建扫描预算 1 ms")
        #endif
    }
}
