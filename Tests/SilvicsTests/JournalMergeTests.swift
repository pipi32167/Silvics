import XCTest
@testable import Silvics

/// 日记待办融合（issue #48）。编号对应 `docs/日记编辑器边界用例.md` 第 4 节 M01–M12。
///
/// 只测 `JournalMerge` 本身：解析、归属、落点、判重、补段。
/// 新建链路与日期来源在 `JournalTests`。
final class JournalMergeTests: XCTestCase {

    private func merge(_ source: String, into target: String) -> JournalMerge.Merge {
        JournalMerge.merge(into: target, from: JournalMerge.openTodos(in: source))
    }

    // MARK: - M01 两个模块各有未完成

    func testM01EachSectionGetsItsOwnItemsInOrder() {
        let source = """
        ## 工作
        - [ ] 一
        - [ ] 二
        ## 生活
        - [ ] 三
        """
        let result = merge(source, into: "## 工作\n\n## 生活\n")
        XCTAssertEqual(result.body, """
        ## 工作
        - [ ] 一
        - [ ] 二

        ## 生活
        - [ ] 三

        """)
        XCTAssertEqual(result.added, 3)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.placements, [
            .init(section: "工作", count: 2),
            .init(section: "生活", count: 1),
        ])
    }

    // MARK: - M02 当天同名段已有别的内容

    func testM02AppendsAfterLastNonEmptyLine() {
        let target = """
        ## 工作
        - [x] 已经做完的

        ## 生活
        - [ ] 买咖啡豆

        ## 日记

        """
        let result = merge("## 工作\n- [ ] 新来的\n", into: target)
        XCTAssertEqual(result.body, """
        ## 工作
        - [x] 已经做完的
        - [ ] 新来的

        ## 生活
        - [ ] 买咖啡豆

        ## 日记

        """)
    }

    // MARK: - M03 当天缺同名段

    func testM03CreatesMissingSectionAtEndOfBody() {
        let result = merge("## 生活\n- [ ] 洗衣服\n", into: "## 工作\n")
        XCTAssertEqual(result.body, "## 工作\n\n## 生活\n- [ ] 洗衣服")
        XCTAssertEqual(result.added, 1)
    }

    func testM03CreatesMissingParentChain() {
        let result = merge("## 工作\n### 部署\n- [ ] 上线\n", into: "## 生活\n")
        XCTAssertEqual(result.body, """
        ## 生活

        ## 工作

        ### 部署
        - [ ] 上线
        """)
    }

    // MARK: - M04 第一条标题之前的待办

    func testM04PreHeadingTodoGoesToFirstSection() {
        let source = """
        - [ ] 前言里的事
        ## 工作
        - [ ] 工作里的事
        """
        let result = merge(source, into: "## 工作\n\n## 生活\n")
        XCTAssertEqual(result.body, """
        ## 工作
        - [ ] 前言里的事
        - [ ] 工作里的事

        ## 生活

        """)
    }

    // MARK: - M05 当天一个标题都没有

    func testM05NoHeadingAppendsToEndOfBody() {
        let result = merge("- [ ] 一句话待办\n", into: "今天写了点东西")
        XCTAssertEqual(result.body, "今天写了点东西\n- [ ] 一句话待办")

        let empty = merge("- [ ] 一句话待办\n", into: "")
        XCTAssertEqual(empty.body, "- [ ] 一句话待办\n")
    }

    // MARK: - M06 当天已有同一条

    func testM06SkipsTextAlreadyPresent() {
        let target = """
        ## 生活
        - [ ] 拿口罩
        - [x] 早睡
        """
        let source = """
        ## 生活
        - [ ] 拿口罩
        - [ ] 早睡
        - [ ] 新的一条
        """
        let result = merge(source, into: target)
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.body, """
        ## 生活
        - [ ] 拿口罩
        - [x] 早睡
        - [ ] 新的一条
        """)
    }

    // MARK: - M07 来源只有已完成

    func testM07NoItemsWhenAllDone() {
        let result = merge("## 工作\n- [x] 做完了\n- [X] 也做完了\n", into: "## 工作\n")
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.body, "## 工作\n")
    }

    // MARK: - M08 代码块里的不算待办

    func testM08FencedCodeIsIgnored() {
        let source = """
        ## 工作
        ```
        - [ ] 代码块里的
        ```
        - [ ] 真事
        """
        let carried = JournalMerge.openTodos(in: source)
        XCTAssertEqual(carried.map(\.text), ["真事"])

        let inline = "示例：`- [ ] 行内`"
        XCTAssertTrue(JournalMerge.openTodos(in: inline).isEmpty)
    }

    // MARK: - M09 同名段出现两次

    func testM09DuplicateHeadingsUseFirst() {
        let target = """
        ## 生活
        - [ ] 上午的
        ## 生活
        - [ ] 下午的
        """
        let result = merge("## 生活\n- [ ] 新来的\n", into: target)
        XCTAssertEqual(result.body, """
        ## 生活
        - [ ] 上午的
        - [ ] 新来的
        ## 生活
        - [ ] 下午的
        """)
    }

    // MARK: - M10 重复触发

    func testM10SecondMergeIsNoOp() {
        let source = "## 工作\n- [ ] 只搬一次\n"
        let first = merge(source, into: "## 工作\n")
        let second = merge(source, into: first.body)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.skipped, 1)
        XCTAssertEqual(second.body, first.body)
    }

    // MARK: - M11 段内全空

    func testM11EmptySectionInsertsRightAfterHeading() {
        let result = merge("## 生活\n- [ ] 一\n", into: "## 生活\n\n\n## 工作\n")
        XCTAssertEqual(result.body, "## 生活\n- [ ] 一\n\n\n## 工作\n")
    }

    // MARK: - M12 条目文本原样

    func testM12ItemTextIsCopiedVerbatim() {
        let source = """
        ## 工作
        - [ ] 读 [[稀疏重复]] 与 `inline code`，保留   多余空格
        """
        let result = merge(source, into: "## 工作\n")
        XCTAssertTrue(
            result.body.contains("- [ ] 读 [[稀疏重复]] 与 `inline code`，保留   多余空格"),
            result.body
        )
        XCTAssertEqual(JournalMerge.todoTexts(in: result.body).count, 1)
    }

    // MARK: - 补充：子标题、嵌套子项、有序列表

    func testSubheadingKeepsItsOwnPath() {
        let source = """
        ## 工作
        ### 部署
        - [ ] 上线
        """
        let target = """
        ## 工作

        ### 部署

        ## 生活
        """
        let result = merge(source, into: target)
        XCTAssertEqual(result.body, """
        ## 工作

        ### 部署
        - [ ] 上线

        ## 生活
        """)
    }

    func testNestedChildrenMoveWithParent() {
        let source = """
        ## 工作
        - [ ] 部署
          - 先备份
        """
        let result = merge(source, into: "## 工作\n")
        XCTAssertEqual(result.body, "## 工作\n- [ ] 部署\n  - 先备份\n")
        XCTAssertEqual(result.added, 1)
    }

    func testOrderedListItemsAreCarried() {
        let source = """
        ## 工作
        1. [ ] 第一步
        2. [ ] 第二步
        """
        let result = merge(source, into: "## 工作\n")
        XCTAssertEqual(result.body, "## 工作\n1. [ ] 第一步\n2. [ ] 第二步\n")
        XCTAssertEqual(result.added, 2)
    }

    // MARK: - 行解析

    func testTodoTextParsing() {
        XCTAssertEqual(JournalMerge.todoText(fromLine: "- [ ] 拿口罩"), "拿口罩")
        XCTAssertEqual(JournalMerge.todoText(fromLine: "  * [x] 完了 "), "完了")
        XCTAssertEqual(JournalMerge.todoText(fromLine: "1) [ ] 编号"), "编号")
        XCTAssertNil(JournalMerge.todoText(fromLine: "- [ ]没有空格"), "`]` 后必须有空白")
        XCTAssertNil(JournalMerge.todoText(fromLine: "- [y] 非法标记"))
        XCTAssertNil(JournalMerge.todoText(fromLine: "普通一段话"))
    }
}
