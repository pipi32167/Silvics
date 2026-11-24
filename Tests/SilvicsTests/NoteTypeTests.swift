import XCTest
@testable import Silvics

/// 批次 1：类型注册表 + frontmatter 分层 + 未知键保留。
final class NoteTypeTests: XCTestCase {

    // MARK: - 注册表

    func testUnknownTypeFallsBackToNote() {
        let descriptor = NoteTypes.descriptor(for: "reading-note")
        XCTAssertEqual(descriptor.id, NoteTypes.noteID)
        XCTAssertTrue(descriptor.linkable)
        XCTAssertFalse(NoteTypes.isKnown("reading-note"))
    }

    func testJournalDescriptorFlags() {
        let journal = NoteTypes.descriptor(for: NoteTypes.journalID)
        XCTAssertEqual(journal.fileDir, "journal")
        XCTAssertFalse(journal.titleEditable)
        XCTAssertFalse(journal.validatesTitle)
        XCTAssertFalse(journal.linkable)
        XCTAssertFalse(journal.inQuickOpen)
        XCTAssertFalse(journal.countsAsOrphan)
        XCTAssertFalse(journal.scanMentions)
        XCTAssertEqual(journal.metaNamespace, "journal")
    }

    func testJournalIDIsDeterministic() {
        XCTAssertEqual(NoteTypes.journalID(for: "2026-11-24"), "j20261124")
        // 两台设备同一天必须算成同一个 id
        XCTAssertEqual(
            NoteTypes.journalID(for: "2026-11-24"),
            NoteTypes.journalID(for: "2026-11-24")
        )
    }

    // MARK: - frontmatter 分层

    private func sample(type: String = NoteTypes.noteID) -> VaultFormat.Note {
        VaultFormat.Note(
            id: "n1",
            title: "稀疏重复优于集中突击",
            status: .evergreen,
            createdAt: 1_700_000_000_000,
            updatedAt: 1_700_000_500_000,
            aliases: ["遗忘规律"],
            dismissed: ["n2"],
            body: "正文\n",
            type: type
        )
    }

    func testTypeLineOmittedForPlainNote() throws {
        let text = VaultFormat.encode(sample())
        XCTAssertFalse(text.contains("\ntype:"), text)
        XCTAssertEqual(try VaultFormat.decode(text).type, NoteTypes.noteID)
    }

    func testTypeAndMetaRenderedForJournal() throws {
        var note = sample(type: NoteTypes.journalID)
        note.title = "2026-11-24"
        note.meta = ["date": "2026-11-24", "carryFrom": "2026-11-23"]
        let text = VaultFormat.encode(note)
        XCTAssertTrue(text.contains("\ntype: journal"), text)
        XCTAssertTrue(text.contains("\njournal:\n  carryFrom: 2026-11-23\n  date: 2026-11-24"), text)

        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.type, NoteTypes.journalID)
        XCTAssertEqual(decoded.meta, ["date": "2026-11-24", "carryFrom": "2026-11-23"])
    }

    func testMetaKeysSorted() {
        var note = sample(type: NoteTypes.journalID)
        note.meta = ["date": "2026-11-24", "carryFrom": "2026-11-23", "aaa": "1"]
        let lines = VaultFormat.encode(note).split(separator: "\n")
        let index = lines.firstIndex(of: "journal:")!
        XCTAssertEqual(String(lines[index + 1]).trimmingCharacters(in: .whitespaces), "aaa: 1")
        XCTAssertEqual(String(lines[index + 2]).trimmingCharacters(in: .whitespaces), "carryFrom: 2026-11-23")
    }

    func testMissingTypeDefaultsToNote() throws {
        // 旧 vault 没有 type 字段
        let legacy = """
        ---
        schema: 1
        id: n1
        title: 旧笔记
        status: seedling
        created: 2026-11-20T00:00:00.000Z
        updated: 2026-11-20T00:00:00.000Z
        ---
        正文
        """
        let decoded = try VaultFormat.decode(legacy)
        XCTAssertEqual(decoded.type, NoteTypes.noteID)
        XCTAssertTrue(decoded.meta.isEmpty)
    }

    // MARK: - 未知键保留

    func testUnknownKeysSurviveRoundTrip() throws {
        let text = """
        ---
        schema: 1
        id: n1
        type: journal
        title: 2026-11-24
        status: seedling
        created: 2026-11-24T00:00:00.000Z
        updated: 2026-11-24T00:00:00.000Z
        aliases:
          - 别名
        futureScalar: 未来版本写的值
        futureList:
          - 一
          - 二
        futureSection:
          alpha: 1
          beta: 2
        journal:
          date: 2026-11-24
        ---
        正文
        """
        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.extra.scalars["futureScalar"], "未来版本写的值")
        XCTAssertEqual(decoded.extra.lists["futureList"], ["一", "二"])
        XCTAssertEqual(decoded.extra.sections["futureSection"], ["alpha": "1", "beta": "2"])
        XCTAssertEqual(decoded.meta["date"], "2026-11-24", "类型段不能被当成未知段")

        let reencoded = VaultFormat.encode(decoded)
        XCTAssertTrue(reencoded.contains("futureScalar: 未来版本写的值"), reencoded)
        XCTAssertTrue(reencoded.contains("futureSection:\n  alpha: 1\n  beta: 2"), reencoded)

        // 再解一次，未知键不能丢也不能变
        let again = try VaultFormat.decode(reencoded)
        XCTAssertEqual(again.extra, decoded.extra)
        XCTAssertEqual(again.meta, decoded.meta)
    }

    func testEncodeIsByteStable() throws {
        var note = sample()
        note.extra.scalars = ["b": "2", "a": "1"]
        note.extra.lists = ["z": ["y", "x"]]
        note.extra.sections = ["s": ["q": "1", "p": "2"]]
        let first = VaultFormat.encode(note)
        let second = VaultFormat.encode(note)
        XCTAssertEqual(first, second)

        // 字典插入顺序不同，输出必须一致
        var shuffled = note
        shuffled.extra.scalars = ["a": "1", "b": "2"]
        XCTAssertEqual(VaultFormat.encode(shuffled), first)
    }

    func testKnownKeysAreNotTreatedAsExtra() throws {
        let decoded = try VaultFormat.decode(VaultFormat.encode(sample()))
        XCTAssertTrue(decoded.extra.isEmpty, "\(decoded.extra)")
    }

    // MARK: - 迁移

    func testFreshDatabaseHasTypeAndMeta() throws {
        let repo = GRDBNoteRepository(db: try AppDatabase.makeInMemory())
        let note = try repo.create(title: "稀疏重复优于集中突击")
        XCTAssertEqual(note.type, NoteTypes.noteID)
        XCTAssertEqual(note.meta, "{}")
        XCTAssertEqual(note.extra, "{}")
        XCTAssertTrue(note.metaFields.isEmpty)
    }

    func testMetaFieldsRoundTripThroughDatabase() throws {
        let repo = GRDBNoteRepository(db: try AppDatabase.makeInMemory())
        var note = try repo.create(title: "2026-11-24")
        note.type = NoteTypes.journalID
        note.setMetaFields(["date": "2026-11-24", "carryFrom": "2026-11-23"])
        _ = try repo.save(note)

        let reloaded = try repo.note(id: note.id)
        XCTAssertEqual(reloaded?.type, NoteTypes.journalID)
        XCTAssertEqual(reloaded?.metaFields["date"], "2026-11-24")
        XCTAssertEqual(reloaded?.metaFields["carryFrom"], "2026-11-23")
    }

    // MARK: - vault 往返

    func testVaultRoundTripKeepsTypeMetaAndUnknownKeys() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = GRDBNoteRepository(db: db)

        var note = try repo.create(title: "2026-11-24")
        note.type = NoteTypes.journalID
        note.setMetaFields(["date": "2026-11-24"])
        var extra = VaultFormat.FrontmatterExtra()
        extra.scalars["futureScalar"] = "保留我"
        extra.lists["futureList"] = ["甲", "乙"]
        note.setFrontmatterExtra(extra)
        note.body = "## 工作\n- [ ] 一件事\n"
        _ = try repo.save(note)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("silvics-type-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var settings = SyncSettings()
        settings.vaultPath = dir.path
        let sync = VaultSync(repo: repo, settings: settings)
        try sync.exportAll()

        let fresh = GRDBNoteRepository(db: try AppDatabase.makeInMemory())
        let restore = VaultSync(repo: fresh, settings: settings)
        _ = try restore.importAll()

        let restored = try fresh.note(id: note.id)
        XCTAssertEqual(restored?.type, NoteTypes.journalID)
        XCTAssertEqual(restored?.metaFields["date"], "2026-11-24")
        XCTAssertEqual(restored?.frontmatterExtra.scalars["futureScalar"], "保留我")
        XCTAssertEqual(restored?.frontmatterExtra.lists["futureList"], ["甲", "乙"])
        XCTAssertEqual(restored?.body, "## 工作\n- [ ] 一件事\n")
    }

    func testExportAfterImportDoesNotLoseUnknownKeys() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = GRDBNoteRepository(db: db)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("silvics-type-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var settings = SyncSettings()
        settings.vaultPath = dir.path
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("notes"), withIntermediateDirectories: true)

        let text = """
        ---
        schema: 1
        id: n9
        title: 带未知键的笔记
        status: seedling
        created: 2026-11-20T00:00:00.000Z
        updated: 2026-11-20T00:00:00.000Z
        futureScalar: 别丢我
        ---
        正文
        """
        try text.write(to: dir.appendingPathComponent("notes/n9.md"), atomically: true, encoding: .utf8)

        let sync = VaultSync(repo: repo, settings: settings)
        _ = try sync.importAll()
        try sync.exportAll()

        let exported = try String(contentsOf: dir.appendingPathComponent("notes/n9.md"), encoding: .utf8)
        XCTAssertTrue(exported.contains("futureScalar: 别丢我"), exported)
    }

    // MARK: - P0-1 不是当前类型的段不能被吞掉

    private func fileWithJournalSection(typeLine: String) -> String {
        """
        ---
        schema: 1
        id: n1
        \(typeLine)title: 旧版本写的日记
        status: seedling
        created: 2026-11-20T00:00:00.000Z
        updated: 2026-11-20T00:00:00.000Z
        journal:
          date: 2026-11-24
          carryFrom: 2026-11-23
        ---
        正文
        """
    }

    func testUnregisteredTypeKeepsJournalSection() throws {
        let text = fileWithJournalSection(typeLine: "type: reading-note\n")
        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.type, "reading-note")
        XCTAssertTrue(decoded.meta.isEmpty, "未注册类型不该把 journal 段当 meta：\(decoded.meta)")
        XCTAssertEqual(decoded.extra.sections["journal"]?["date"], "2026-11-24", "\(decoded.extra)")
        XCTAssertEqual(decoded.extra.sections["journal"]?["carryFrom"], "2026-11-23")

        let reencoded = VaultFormat.encode(decoded)
        XCTAssertTrue(reencoded.contains("journal:\n  carryFrom: 2026-11-23\n  date: 2026-11-24"), reencoded)

        let again = try VaultFormat.decode(reencoded)
        XCTAssertEqual(again.type, "reading-note")
        XCTAssertEqual(again.extra, decoded.extra, "段必须原样回来")
    }

    func testMissingTypeKeepsJournalSection() throws {
        let text = fileWithJournalSection(typeLine: "")
        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.type, NoteTypes.noteID)
        XCTAssertTrue(decoded.meta.isEmpty, "\(decoded.meta)")
        XCTAssertEqual(decoded.extra.sections["journal"]?["date"], "2026-11-24", "\(decoded.extra)")

        let again = try VaultFormat.decode(VaultFormat.encode(decoded))
        XCTAssertEqual(again.extra.sections["journal"]?["carryFrom"], "2026-11-23", "\(again.extra)")
    }

    func testMetaWithoutNamespaceIsWrittenAsSection() throws {
        // 未注册类型 + 库里已有 meta：没有 `journal:` 之类的命名空间可用，也不能丢。
        var note = sample(type: "reading-note")
        note.meta = ["date": "2026-11-24"]
        let text = VaultFormat.encode(note)
        XCTAssertTrue(text.contains("\nreading-note:\n  date: 2026-11-24"), text)

        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.type, "reading-note")
        XCTAssertEqual(decoded.extra.sections["reading-note"]?["date"], "2026-11-24", "\(decoded.extra)")
    }

    // MARK: - P1-3 空段与空值字段
    func testUnregisteredTypeSectionSurvivesVaultRoundTrip() throws {
        let repo = GRDBNoteRepository(db: try AppDatabase.makeInMemory())
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("silvics-type-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("notes"), withIntermediateDirectories: true
        )

        var settings = SyncSettings()
        settings.vaultPath = dir.path
        let sync = VaultSync(repo: repo, settings: settings)
        try fileWithJournalSection(typeLine: "type: reading-note\n")
            .write(to: dir.appendingPathComponent("notes/n1.md"), atomically: true, encoding: .utf8)

        _ = try sync.importAll()
        XCTAssertEqual(try repo.note(id: "n1")?.type, "reading-note")
        XCTAssertEqual(
            try repo.note(id: "n1")?.frontmatterExtra.sections["journal"]?["date"],
            "2026-11-24",
            "未注册类型的 journal 段要进未知层，不能丢"
        )

        try sync.exportAll()
        let exported = try String(contentsOf: dir.appendingPathComponent("notes/n1.md"), encoding: .utf8)
        XCTAssertTrue(exported.contains("journal:\n  carryFrom: 2026-11-23\n  date: 2026-11-24"), exported)
    }


    /// 未知层里出现过的键（scalars / lists / sections 三部分）。
    private func frontmatterKeys(_ extra: VaultFormat.FrontmatterExtra) -> Set<String> {
        Set(extra.scalars.keys).union(extra.lists.keys).union(extra.sections.keys)
    }

    func testEmptySectionAndEmptyScalarSurviveRoundTrip() throws {
        let text = """
        ---
        schema: 1
        id: n1
        title: 空值测试
        status: seedling
        created: 2026-11-20T00:00:00.000Z
        updated: 2026-11-20T00:00:00.000Z
        emptySection:
        futureScalar:
        ---
        正文
        """
        let decoded = try VaultFormat.decode(text)
        let keys = frontmatterKeys(decoded.extra)
        XCTAssertTrue(keys.contains("emptySection"), "\(decoded.extra)")
        XCTAssertTrue(keys.contains("futureScalar"), "\(decoded.extra)")

        let reencoded = VaultFormat.encode(decoded)
        XCTAssertTrue(reencoded.contains("\nemptySection:\n"), reencoded)
        XCTAssertTrue(reencoded.contains("\nfutureScalar:\n"), reencoded)

        let again = try VaultFormat.decode(reencoded)
        XCTAssertEqual(frontmatterKeys(again.extra), keys, "键集合必须相等")
        XCTAssertEqual(again.extra, decoded.extra)
    }

    // MARK: - P1-4 缩进宽度

    func testFourSpaceIndentKeepsInnerKeyClean() throws {
        let text = """
        ---
        schema: 1
        id: n1
        type: journal
        title: 2026-11-24
        status: seedling
        created: 2026-11-24T00:00:00.000Z
        updated: 2026-11-24T00:00:00.000Z
        journal:
            date: 2026-11-24
        ---
        正文
        """
        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.meta["date"], "2026-11-24", "\(decoded.meta)")
        XCTAssertNil(decoded.meta["  date"], "键名不能被缩进污染：\(decoded.meta)")
    }

    // MARK: - P1-5 深层嵌套整块保留

    func testNestedSectionKeepsEveryRawLine() throws {
        let text = """
        ---
        schema: 1
        id: n1
        title: 嵌套段
        status: seedling
        created: 2026-11-20T00:00:00.000Z
        updated: 2026-11-20T00:00:00.000Z
        clip:
          url: x
          tags:
            - 一
            - 二
        ---
        正文
        """
        let decoded = try VaultFormat.decode(text)
        XCTAssertNil(decoded.extra.sections["clip"], "解析不了的段不能压成半截字典：\(decoded.extra)")
        XCTAssertEqual(decoded.extra.rawSections["clip"]?.count, 4, "\(decoded.extra)")

        let reencoded = VaultFormat.encode(decoded)
        XCTAssertTrue(reencoded.contains("    - 一"), reencoded)
        XCTAssertTrue(reencoded.contains("    - 二"), reencoded)

        let again = try VaultFormat.decode(reencoded)
        XCTAssertEqual(again.extra.rawSections["clip"], decoded.extra.rawSections["clip"])
    }
}
