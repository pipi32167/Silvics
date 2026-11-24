import XCTest
@testable import Silvics

final class VaultFormatTests: XCTestCase {

    private func sample() -> VaultFormat.Note {
        VaultFormat.Note(
            id: "n1001abc",
            title: "稀疏重复优于集中突击",
            status: .evergreen,
            createdAt: 1_700_000_000_000,
            updatedAt: 1_700_000_500_000,
            aliases: ["遗忘规律", "记忆规律"],
            dismissed: ["n2002def"],
            body: "第一段。\n\n第二段带 [[引用]]。\n"
        )
    }

    func testRoundTrip() throws {
        let original = sample()
        let decoded = try VaultFormat.decode(VaultFormat.encode(original))
        // 别名按字典序落盘，顺序不是语义
        XCTAssertEqual(decoded.aliases, original.aliases.sorted())
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.updatedAt, original.updatedAt)
        XCTAssertEqual(decoded.dismissed, original.dismissed)
        XCTAssertEqual(decoded.body, original.body)
    }

    func testEncodeIsByteStable() {
        let note = sample()
        let a = VaultFormat.encode(note)
        let b = VaultFormat.encode(note)
        XCTAssertEqual(a, b)
        // 别名与忽略项按字典序输出，输入顺序不影响结果
        var shuffled = note
        shuffled.aliases = ["记忆规律", "遗忘规律"]
        XCTAssertEqual(VaultFormat.encode(shuffled), a)
    }

    func testTitlesWithColonSurvive() throws {
        for title in ["为什么：标题要写成断言句", "A:B 的标题", "带 空格 的标题", "#井号开头"] {
            var note = sample()
            note.title = title
            XCTAssertEqual(try VaultFormat.decode(VaultFormat.encode(note)).title, title, title)
        }
    }

    func testTitleWithLeadingSpaceIsQuoted() throws {
        var note = sample()
        note.title = " 前面有空格"
        let text = VaultFormat.encode(note)
        XCTAssertTrue(text.contains("title: \" 前面有空格\""), text)
        XCTAssertEqual(try VaultFormat.decode(text).title, " 前面有空格")
    }

    func testEmptyBodyKeepsTrailingStructure() throws {
        var note = sample()
        note.body = ""
        let decoded = try VaultFormat.decode(VaultFormat.encode(note))
        XCTAssertEqual(decoded.body, "")
    }

    func testUnknownKeysIgnored() throws {
        var text = VaultFormat.encode(sample())
        text = text.replacingOccurrences(of: "schema: 1\n", with: "schema: 1\nfutureKey: whatever\n")
        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.id, "n1001abc")
    }

    func testHashIsStableAcrossRuns() {
        // 值写死在这里：一旦实现改成随机种子的哈希，这个测试会立刻红。
        XCTAssertEqual(VaultFormat.hash(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            VaultFormat.hash("遗忘曲线"),
            VaultFormat.hash("遗忘曲线")
        )
    }

    func testManifestIsStable() {
        let notes = [sample(), {
            var n = sample()
            n.id = "n1000aaa"
            return n
        }()]
        let a = VaultFormat.encodeManifest(VaultFormat.makeManifest(notes))
        let b = VaultFormat.encodeManifest(VaultFormat.makeManifest(notes.reversed()))
        XCTAssertEqual(a, b)
        XCTAssertEqual(VaultFormat.decodeManifest(a)?.count, 2)
    }

    func testMalformedFileThrows() {
        XCTAssertThrowsError(try VaultFormat.decode("没有 frontmatter 的正文"))
        XCTAssertThrowsError(try VaultFormat.decode("---\nid: x\n---\n"))
    }
}

final class VaultRoundTripTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("silvics-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeRepo() throws -> GRDBNoteRepository {
        GRDBNoteRepository(db: try AppDatabase.makeInMemory())
    }

    private func makeSync(_ repo: GRDBNoteRepository, vault: URL) -> VaultSync {
        var settings = SyncSettings()
        settings.vaultPath = vault.path
        return VaultSync(repo: repo, settings: settings)
    }

    func testExportIsIdempotent() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = "正文一段。"
        _ = try repo.save(note)

        let sync = makeSync(repo, vault: tmp)
        let first = try sync.exportAll()
        XCTAssertGreaterThan(first, 0)
        let second = try sync.exportAll()
        XCTAssertEqual(second, 0, "同样内容第二次导出不应写任何文件")
    }

    func testAliasesAndDismissedSurviveRoundTrip() throws {
        let repo = try makeRepo()
        let target = try repo.create(title: "遗忘曲线决定长期留存")
        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = "这里提到遗忘曲线决定长期留存。"
        _ = try repo.save(source)
        _ = try repo.addAlias(noteId: source.id, name: "间隔复习")
        if let mention = try repo.mentions(in: source.id).first {
            try repo.dismissMention(id: mention.id)
        }

        let sync = makeSync(repo, vault: tmp)
        try sync.exportAll()

        // 清空库再恢复
        let fresh = try makeRepo()
        let restore = makeSync(fresh, vault: tmp)
        let report = try restore.importAll()
        XCTAssertEqual(report.inserted, 2)

        XCTAssertEqual(try fresh.aliases(noteId: source.id), ["间隔复习"])
        XCTAssertEqual(try fresh.mentions(in: source.id).count, 0, "被忽略的提及恢复后仍是忽略状态")
        XCTAssertNotNil(try fresh.note(id: target.id))
        XCTAssertEqual(try fresh.note(id: source.id)?.body, "这里提到遗忘曲线决定长期留存。")
    }

    func testImportRejectsTitleTakenByAnotherId() throws {
        let repo = try makeRepo()
        _ = try repo.create(title: "稀疏重复优于集中突击")

        let sync = makeSync(repo, vault: tmp)
        var incoming = VaultFormat.Note(
            id: "n_from_other_device",
            title: "稀疏重复优于集中突击",
            status: .seedling,
            createdAt: 1, updatedAt: 2,
            aliases: [], dismissed: [], body: "别人的版本"
        )
        incoming.body = "别人的版本"
        let report = try repo.importVaultNotes([incoming])
        XCTAssertEqual(report.inserted, 0)
        XCTAssertEqual(report.titleConflicts.count, 1)
        // 本地正文没被覆盖
        let existing = try repo.vaultNotes().first { $0.title == incoming.title }
        XCTAssertNotEqual(existing?.body, "别人的版本")
    }

    func testDeletePropagatesThroughVault() throws {
        let repo = try makeRepo()
        let note = try repo.create(title: "会被删掉的笔记")
        let sync = makeSync(repo, vault: tmp)
        try sync.exportAll()

        let file = sync.notesURL.appendingPathComponent(VaultFormat.fileName(for: note.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        try repo.delete(id: note.id)
        try sync.removeFromVault(id: note.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "删笔记要把 vault 里的文件也删掉")

        // 导出本身绝不删文件：库空了也不能把备份清空
        try sync.exportAll()
        XCTAssertEqual(try sync.readVaultNotes().count, 0)
    }

    func testEmptyDatabaseRestoresFromVault() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "换机器之后要能恢复")
        note.body = "正文不能丢。"
        _ = try repo.save(note)
        let sync = makeSync(repo, vault: tmp)
        try sync.exportAll()

        // 模拟换机器：全新的空库，同一份 vault
        let fresh = try makeRepo()
        let restore = makeSync(fresh, vault: tmp)
        try restore.exportAll()
        XCTAssertEqual(try restore.readVaultNotes().count, 1, "空库导出不能删掉已有的 vault 文件")
        _ = try restore.importAll()
        XCTAssertEqual(try fresh.summaries().count, 1)
        XCTAssertEqual(try fresh.note(id: note.id)?.body, "正文不能丢。")
    }

    func testVerifyDetectsTamperedHash() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "校验要能失败")
        note.body = "原文"
        _ = try repo.save(note)

        let sync = makeSync(repo, vault: tmp)
        try sync.exportAll()
        XCTAssertTrue(try sync.verify().ok)

        // 手工改坏正文，但不改 manifest
        let file = sync.notesURL.appendingPathComponent(VaultFormat.fileName(for: note.id))
        let text = try String(contentsOf: file, encoding: .utf8)
        try text.replacingOccurrences(of: "原文", with: "被改坏").write(to: file, atomically: true, encoding: .utf8)

        let result = try sync.verify()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.problems.contains { $0.contains("哈希") }, result.problems.joined(separator: " / "))
    }
}
