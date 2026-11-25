import XCTest
@testable import Silvics

/// 模板正文注入骨架 + 面板内的增删改（`templates/<名字>.md`）。
///
/// 与 `JournalTests` 的分工：那边测「勾选记忆决定用哪些模板」，
/// 这里测「模板文件本身怎么读写」与「正文怎么进骨架」。
final class JournalTemplateManagementTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 记忆落真实 UserDefaults：每个用例换独立 suite，否则本机勾选会改变结果。
        JournalTemplateMemory.defaults = UserDefaults(suiteName: "silvics.tests.mgmt.\(UUID().uuidString)") ?? .standard
    }

    override func tearDown() {
        JournalTemplateMemory.defaults = .standard
        super.tearDown()
    }

    private let vault = TempVault("template-mgmt")

    private func makeRepo() throws -> GRDBNoteRepository {
        vault.repo(try AppDatabase.makeInMemory())
    }

    private var templatesDir: URL {
        vault.url.appendingPathComponent(VaultFormat.templatesDir, isDirectory: true)
    }

    private func templateURL(_ name: String) -> URL {
        templatesDir.appendingPathComponent("\(name).md")
    }

    private func templateText(_ name: String) throws -> String {
        try String(contentsOf: templateURL(name), encoding: .utf8)
    }

    private func templateFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: templatesDir.path)) ?? []).sorted()
    }

    // MARK: - 1. 骨架注入正文（含 `- [ ]`）

    func testSkeletonInjectsTemplateBody() throws {
        try JournalTemplates.create(
            name: "工作", order: "1",
            body: "- [ ] 写批次 7 的测试\n- [ ] 接模板管理面板",
            in: vault.url
        )
        try JournalTemplates.create(
            name: "生活", order: "2",
            body: "- [ ] 跑步 20 分钟",
            in: vault.url
        )

        let expected = """
        ## 工作
        - [ ] 写批次 7 的测试
        - [ ] 接模板管理面板

        ## 生活
        - [ ] 跑步 20 分钟

        """
        XCTAssertEqual(JournalTemplates.skeleton(named: ["生活", "工作"], in: vault.url), expected)

        // 走真实新建链路，落库正文与骨架一致；`- [ ]` 原样保留，承接扫得到。
        let repo = try makeRepo()
        let today = try repo.journalNote(on: "2026-11-24", using: ["生活", "工作"])
        XCTAssertEqual(today.body, expected)
        XCTAssertEqual(JournalCarry.openTodos(in: today.body).count, 3)
    }

    // MARK: - 2. 无正文只有标题

    func testSkeletonWithoutBodyHasNoExtraBlankLine() throws {
        try JournalTemplates.create(name: "工作", order: "1", body: "", in: vault.url)
        try JournalTemplates.create(name: "生活", order: "2", body: "   \n\n", in: vault.url)

        XCTAssertEqual(JournalTemplates.skeleton(named: ["工作", "生活"], in: vault.url), "## 工作\n\n## 生活\n")

        let repo = try makeRepo()
        let today = try repo.journalNote(on: "2026-11-24", using: ["工作", "生活"])
        XCTAssertEqual(today.body, "## 工作\n\n## 生活\n")
        XCTAssertFalse(today.body.contains("\n\n\n"), "段间不能出现两个空行：\(today.body)")
    }

    // MARK: - 3. 正文前后空行裁掉、段间恰好一个空行

    func testSkeletonTrimsBlankLinesAroundAndBetweenParagraphs() throws {
        try JournalTemplates.create(
            name: "工作", order: "1",
            body: "\n\n第一段：写下来。\n\n\n\n第二段：再补理由。\n\n",
            in: vault.url
        )

        let skeleton = JournalTemplates.skeleton(named: ["工作"], in: vault.url)
        XCTAssertEqual(skeleton, "## 工作\n第一段：写下来。\n\n第二段：再补理由。\n")

        // 正文首尾不能有空行残留。
        XCTAssertFalse(skeleton.hasPrefix("## 工作\n\n"))
        XCTAssertFalse(skeleton.hasSuffix("\n\n"))
    }

    // MARK: - 4. 新建：文件生成在 templates/，frontmatter 有 name/order

    func testCreateTemplateWritesFileWithFrontmatter() throws {
        let created = try JournalTemplates.create(
            name: " 工作 ", order: " 3 ",
            body: "- [ ] 写测试",
            in: vault.url
        )

        XCTAssertEqual(created.name, "工作", "名字去首尾空白")
        XCTAssertEqual(created.order, 3)
        XCTAssertEqual(created.path, "templates/工作.md")
        XCTAssertEqual(templateFiles(), ["工作.md"])

        let text = try templateText("工作")
        XCTAssertTrue(text.hasPrefix("---\n"), text)
        XCTAssertTrue(text.contains("template:\n  name: 工作\n  order: 3\n"), text)
        XCTAssertTrue(text.hasSuffix("---\n- [ ] 写测试\n"), text)

        // 读回来一致：frontmatter 的 name/order 与正文都对得上。
        let loaded = try XCTUnwrap(JournalTemplates.load(in: vault.url).first)
        XCTAssertEqual(loaded.name, "工作")
        XCTAssertEqual(loaded.order, 3)
        XCTAssertEqual(JournalTemplates.normalizeBody(loaded.body), "- [ ] 写测试")
    }

    // MARK: - 5. 编辑正文：文件内容更新

    func testUpdateTemplateBodyRewritesFile() throws {
        let created = try JournalTemplates.create(
            name: "工作", order: "1", body: "- [ ] 旧的", in: vault.url
        )
        let updated = try JournalTemplates.update(
            created, name: "工作", order: "1", body: "- [ ] 新的\n- [ ] 再加一条", in: vault.url
        )

        XCTAssertEqual(updated.path, created.path)
        XCTAssertEqual(templateFiles(), ["工作.md"], "编辑不能多出第二份文件")
        let text = try templateText("工作")
        XCTAssertTrue(text.contains("- [ ] 新的"), text)
        XCTAssertTrue(text.contains("- [ ] 再加一条"), text)
        XCTAssertFalse(text.contains("旧的"), text)

        XCTAssertEqual(
            JournalTemplates.skeleton(named: ["工作"], in: vault.url),
            "## 工作\n- [ ] 新的\n- [ ] 再加一条\n"
        )
    }

    // MARK: - 6. 改名：新文件存在、旧文件不存在

    func testRenameTemplateMovesFile() throws {
        let created = try JournalTemplates.create(
            name: "工作", order: "1", body: "- [ ] 写测试", in: vault.url
        )
        let renamed = try JournalTemplates.update(
            created, name: "深度工作", order: "1", body: "- [ ] 写测试", in: vault.url
        )

        XCTAssertEqual(renamed.name, "深度工作")
        XCTAssertEqual(renamed.path, "templates/深度工作.md")
        XCTAssertEqual(templateFiles(), ["深度工作.md"], "改名要删掉旧文件，不能留两份")
        XCTAssertFalse(FileManager.default.fileExists(atPath: templateURL("工作").path))
        XCTAssertTrue(try templateText("深度工作").contains("  name: 深度工作\n"))

        XCTAssertEqual(JournalTemplates.load(in: vault.url).map(\.name), ["深度工作"])
    }

    // MARK: - 7. 删除：只删这一份

    func testDeleteTemplateRemovesOnlyThatFile() throws {
        let work = try JournalTemplates.create(name: "工作", order: "1", body: "- [ ] 写", in: vault.url)
        try JournalTemplates.create(name: "生活", order: "2", body: "- [ ] 跑", in: vault.url)

        try JournalTemplates.delete(work, in: vault.url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: templateURL("工作").path))
        XCTAssertEqual(templateFiles(), ["生活.md"], "其它模板不受影响")
        XCTAssertEqual(JournalTemplates.load(in: vault.url).map(\.name), ["生活"])
    }

    // MARK: - 8. 重名被拒

    func testDuplicateNameRejected() throws {
        try JournalTemplates.create(name: "工作", order: "1", body: "", in: vault.url)

        XCTAssertThrowsError(try JournalTemplates.create(name: "工作", order: "2", body: "", in: vault.url)) { error in
            XCTAssertEqual(error as? JournalTemplates.TemplateError, .duplicateName("工作"))
        }

        // 编辑时改成已存在的名字也要拦。
        let other = try JournalTemplates.create(name: "生活", order: "2", body: "", in: vault.url)
        XCTAssertThrowsError(
            try JournalTemplates.update(other, name: "工作", order: "2", body: "", in: vault.url)
        ) { error in
            XCTAssertEqual(error as? JournalTemplates.TemplateError, .duplicateName("工作"))
        }

        // 原文件没被改坏，也没有多出文件。
        XCTAssertEqual(templateFiles(), ["工作.md", "生活.md"])
        XCTAssertEqual(JournalTemplates.load(in: vault.url).first(where: { $0.name == "生活" })?.order, 2)
    }

    // MARK: - 9. 名字含 `/` 被拒

    func testNameWithSlashRejected() throws {
        XCTAssertThrowsError(
            try JournalTemplates.create(name: "工作/日", order: "1", body: "", in: vault.url)
        ) { error in
            XCTAssertEqual(error as? JournalTemplates.TemplateError, .nameHasSlash("工作/日"))
        }

        XCTAssertTrue(templateFiles().isEmpty, "被拒的名字不能落地：\(templateFiles())")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: vault.url.appendingPathComponent("工作/日.md").path)
        )
    }

    // MARK: - 10. order 非数字被拒

    func testOrderNotNumberRejected() throws {
        // 策略：直接拒绝，不静默回落成「排最后」——写错要人看见。
        XCTAssertThrowsError(
            try JournalTemplates.create(name: "工作", order: "一", body: "", in: vault.url)
        ) { error in
            XCTAssertEqual(error as? JournalTemplates.TemplateError, .orderNotNumber("一"))
        }
        XCTAssertThrowsError(
            try JournalTemplates.create(name: "工作", order: "  ", body: "", in: vault.url)
        ) { error in
            XCTAssertEqual(error as? JournalTemplates.TemplateError, .orderNotNumber("  "))
        }
        XCTAssertTrue(templateFiles().isEmpty)

        // 文件里手写的非法 order 仍然按 `load` 的老口径当作「排最后」，不因为面板校验改了读取行为。
        try FileManager.default.createDirectory(at: templatesDir, withIntermediateDirectories: true)
        try "---\ntemplate:\n  name: 手写\n  order: 一\n---\n"
            .write(to: templateURL("手写"), atomically: true, encoding: .utf8)
        XCTAssertEqual(JournalTemplates.load(in: vault.url).first?.order, JournalTemplates.unorderedOrder)
    }

    // MARK: - 11. 空名字被拒

    func testEmptyNameRejected() throws {
        XCTAssertThrowsError(try JournalTemplates.create(name: "   ", order: "1", body: "", in: vault.url)) { error in
            XCTAssertEqual(error as? JournalTemplates.TemplateError, .emptyName)
        }
        XCTAssertTrue(templateFiles().isEmpty)
    }

    // MARK: - 12. 保存后立即生效

    func testSavedTemplateTakesEffectOnNextJournal() throws {
        let repo = try makeRepo()
        // 先空手建一篇，确认没有模板时骨架为空。
        let first = try repo.journalNote(on: "2026-11-24", using: JournalTemplates.newJournalNames(in: vault.url))
        XCTAssertEqual(first.body, "")

        try JournalTemplates.create(name: "工作", order: "1", body: "- [ ] 写模板测试", in: vault.url)

        // 不重启、不重载：下一次新建直接读到新模板。
        let names = JournalTemplates.newJournalNames(in: vault.url)
        XCTAssertEqual(names, ["工作"])
        let second = try repo.journalNote(on: "2026-11-25", using: names)
        XCTAssertTrue(second.body.hasPrefix("## 工作\n- [ ] 写模板测试"), second.body)
    }

    // MARK: - 13. 删掉最后一个模板后新建：骨架为空，不崩

    func testNewJournalAfterDeletingLastTemplateHasEmptySkeleton() throws {
        let only = try JournalTemplates.create(name: "工作", order: "1", body: "第一段。", in: vault.url)
        let repo = try makeRepo()
        let first = try repo.journalNote(on: "2026-11-24", using: ["工作"])
        XCTAssertEqual(first.body, "## 工作\n第一段。\n")

        try JournalTemplates.delete(only, in: vault.url)
        XCTAssertEqual(JournalTemplates.defaultNames(in: vault.url), [])
        XCTAssertEqual(JournalTemplates.newJournalNames(in: vault.url), [])
        XCTAssertEqual(JournalTemplates.skeleton(named: ["工作"], in: vault.url), "", "点名的模板文件没了就跳过")

        // 上一篇没有未完成项，所以承接不会插东西：正文应当就是空的。
        let second = try repo.journalNote(on: "2026-11-25", using: JournalTemplates.newJournalNames(in: vault.url))
        XCTAssertEqual(second.body, "")
        XCTAssertEqual(second.title, "2026-11-25")
    }
}
