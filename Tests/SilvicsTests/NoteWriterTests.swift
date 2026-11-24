import XCTest
@testable import Silvics

/// 保存链路倒转：先写 vault 文件，再更新 sqlite 索引。
///
/// 验收标准一句话：删掉 silvics.sqlite，启动后能从 vault 全量重建，内容与操作结果一致。
final class NoteWriterTests: XCTestCase {

    private var vault: TempVault!

    override func setUpWithError() throws {
        vault = TempVault("writer")
    }

    override func tearDownWithError() throws {
        vault = nil
    }

    private func makeRepo() throws -> GRDBNoteRepository {
        vault.repo(try AppDatabase.makeInMemory())
    }

    // MARK: - 文件先写

    func testSaveWritesFileAndDatabaseAgree() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = "第一段。\n\n第二段带 [[间隔重复]]。"
        let outcome = try repo.saveDetailed(note)

        XCTAssertTrue(outcome.wroteFile, "第一次保存必须真的写文件")
        XCTAssertTrue(vault.fileExists(note.id), "vault 里要有 notes/\(note.id).md")

        let onDisk = try VaultFormat.decode(vault.fileText(note.id))
        let inDB = try XCTUnwrap(repo.note(id: note.id))
        XCTAssertEqual(onDisk.id, inDB.id)
        XCTAssertEqual(onDisk.title, inDB.title)
        XCTAssertEqual(onDisk.status, inDB.status)
        XCTAssertEqual(onDisk.body, inDB.body)
        XCTAssertEqual(onDisk.createdAt, inDB.createdAt)
        XCTAssertEqual(onDisk.updatedAt, inDB.updatedAt, "文件与库的时间戳必须一致")
        XCTAssertEqual(onDisk.type, inDB.type)
        XCTAssertEqual(inDB.titleKey, TextNormalizer.key(note.title))
    }

    func testRepeatedSaveOfSameContentTouchesNothing() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "重复保存不应该改写文件")
        note.body = "内容不变。"
        _ = try repo.save(note)

        let before = try Data(contentsOf: vault.fileURL(note.id))
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: vault.fileURL(note.id).path)
        let beforeDate = try XCTUnwrap(beforeAttributes[.modificationDate] as? Date)

        var same = try XCTUnwrap(repo.note(id: note.id))
        let second = try repo.saveDetailed(same)
        XCTAssertFalse(second.wroteFile, "内容没变就一个字节都不碰")
        XCTAssertEqual(second.note.updatedAt, same.updatedAt, "内容没变不能动 updatedAt")

        // 再来一次，且用一个「时间戳故意落后」的副本，也必须判为未变
        same.updatedAt = second.note.updatedAt
        let third = try repo.saveDetailed(same)
        XCTAssertFalse(third.wroteFile)

        let after = try Data(contentsOf: vault.fileURL(note.id))
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: vault.fileURL(note.id).path)
        let afterDate = try XCTUnwrap(afterAttributes[.modificationDate] as? Date)
        XCTAssertEqual(before, after)
        XCTAssertEqual(beforeDate, afterDate, "mtime 都不该抖")
    }

    func testChangedContentIsWrittenAndBumpsTimestamp() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "改了正文就要写文件")
        note.body = "旧正文"
        let first = try repo.saveDetailed(note)
        var again = try XCTUnwrap(repo.note(id: note.id))
        again.body = "新正文"
        let second = try repo.saveDetailed(again)

        XCTAssertTrue(second.wroteFile)
        XCTAssertGreaterThanOrEqual(second.note.updatedAt, first.note.updatedAt)
        XCTAssertTrue(try vault.fileText(note.id).contains("新正文"))
        XCTAssertEqual(try repo.note(id: note.id)?.body, "新正文")
    }

    func testSaveKeepsUnknownFrontmatterKeys() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "未知键要原样保留")
        var extra = VaultFormat.FrontmatterExtra()
        extra.scalars["futureScalar"] = "别丢我"
        extra.lists["futureList"] = ["甲", "乙"]
        extra.sections["futureSection"] = ["k1": "v1"]
        note.setFrontmatterExtra(extra)
        note.body = "正文"
        _ = try repo.save(note)

        let text = try vault.fileText(note.id)
        XCTAssertTrue(text.contains("futureScalar: 别丢我"), text)
        XCTAssertTrue(text.contains("futureList:"), text)
        XCTAssertTrue(text.contains("futureSection:"), text)

        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.extra.scalars["futureScalar"], "别丢我")
        XCTAssertEqual(decoded.extra.lists["futureList"], ["甲", "乙"])
        XCTAssertEqual(decoded.extra.sections["futureSection"], ["k1": "v1"])
        XCTAssertEqual(try repo.note(id: note.id)?.frontmatterExtra.scalars["futureScalar"], "别丢我")
    }

    // MARK: - 文件写失败

    func testVaultWriteFailureLeavesDatabaseUntouched() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "写不进去的时候库不能变")
        note.body = "旧正文"
        _ = try repo.save(note)

        let beforeFile = try Data(contentsOf: vault.fileURL(note.id))
        let beforeRow = try XCTUnwrap(repo.note(id: note.id))

        // vault 的 notes 目录设成只读：写文件一定失败。
        let dir = vault.notesURL
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }

        var changed = beforeRow
        changed.body = "新正文，本该写不进去"
        XCTAssertThrowsError(try repo.save(changed)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("写 vault 文件失败"), text)
        }

        XCTAssertEqual(try repo.note(id: note.id)?.body, "旧正文", "文件没写成，库不能改")
        XCTAssertEqual(try Data(contentsOf: vault.fileURL(note.id)), beforeFile, "旧文件也不能被破坏")
        XCTAssertFalse(try repo.isIndexDirty(), "文件没写成，不该标索引过期")
    }

    // MARK: - 库写失败

    func testDatabaseWriteFailureMarksIndexDirtyAndThrows() throws {
        let repo = try makeRepo()
        _ = try repo.create(title: "先占住这个标题")

        // 把 FTS 表拿掉：文件能写，库事务会失败并回滚。这是「库写失败」的最小复现。
        try repo.db.writer.write { conn in
            try conn.execute(sql: "DROP TABLE note_fts")
        }

        var failing = Note.draft(title: "库写失败也要保住内容")
        failing.body = "这篇只能从文件里找回来。"
        XCTAssertThrowsError(try repo.save(failing)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("索引更新失败"), text)
        }

        XCTAssertTrue(vault.fileExists(failing.id), "文件已经落盘，它是真相")
        XCTAssertTrue(try repo.isIndexDirty(), "库写失败要标 indexDirty，下次启动全量重算")
        XCTAssertNil(try repo.note(id: failing.id), "库里不该有这一篇（事务回滚了）")
    }

    // MARK: - 删库重建

    func testRebuildFromVaultRestoresEverything() throws {
        // 1. 建库、写三篇：普通（含别名与忽略项）、日记、带未知键。
        let db = try AppDatabase.makeInMemory()
        let repo = vault.repo(db)

        let target = try repo.create(title: "间隔重复")
        var targetNote = target
        targetNote.body = "间隔重复优于集中突击。"
        _ = try repo.save(targetNote)

        var plain = try repo.create(title: "稀疏重复优于集中突击")
        plain.body = "提到间隔重复，还有 [[遗忘曲线]]。"
        _ = try repo.save(plain)
        XCTAssertNil(try repo.addAlias(noteId: plain.id, name: "间隔复习的威力"))
        let mention = try XCTUnwrap(try repo.mentions(in: plain.id).first)
        try repo.dismissMention(id: mention.id)

        var journal = try repo.create(title: "2026-11-24")
        journal.type = NoteTypes.journalID
        journal.setMetaFields(["date": "2026-11-24", "carryFrom": "2026-11-23"])
        journal.body = "## 工作\n- [ ] 一件事\n"
        _ = try repo.save(journal)

        var unknown = try repo.create(title: "未知键要原样保留")
        var extra = VaultFormat.FrontmatterExtra()
        extra.scalars["futureScalar"] = "别丢我"
        extra.lists["futureList"] = ["甲", "乙"]
        unknown.setFrontmatterExtra(extra)
        unknown.body = "带未知 frontmatter 键。"
        _ = try repo.save(unknown)

        let expected = try repo.vaultNotes()
        XCTAssertEqual(expected.count, 4)

        // 2. 模拟删掉 silvics.sqlite：全新的空库，同一份 vault。
        let fresh = vault.repo(try AppDatabase.makeInMemory())
        XCTAssertEqual(try fresh.summaries().count, 0)

        let message = try fresh.repairFromVaultIfNeeded()
        XCTAssertNotNil(message, "库空、vault 有文件时必须自动全量导入")
        XCTAssertFalse(try fresh.isIndexDirty(), "自愈完要清掉 indexDirty")

        // 3. 逐项比对
        let actual = try fresh.vaultNotes()
        XCTAssertEqual(actual.count, expected.count)

        for want in expected {
            let got = try XCTUnwrap(actual.first { $0.id == want.id }, "缺 \(want.id)")
            XCTAssertEqual(got.title, want.title)
            XCTAssertEqual(got.type, want.type)
            XCTAssertEqual(got.status, want.status)
            XCTAssertEqual(got.body, want.body)
            XCTAssertEqual(got.aliases.sorted(), want.aliases.sorted())
            XCTAssertEqual(got.dismissed.sorted(), want.dismissed.sorted())
            XCTAssertEqual(got.meta, want.meta)
            XCTAssertEqual(got.extra, want.extra)
        }

        XCTAssertEqual(try fresh.aliases(noteId: plain.id), ["间隔复习的威力"])
        XCTAssertEqual(try fresh.mentions(in: plain.id).count, 0, "忽略过的提及重建后仍是忽略状态")
        XCTAssertEqual(try fresh.note(id: journal.id)?.metaFields["carryFrom"], "2026-11-23")
        XCTAssertEqual(try fresh.note(id: unknown.id)?.frontmatterExtra.scalars["futureScalar"], "别丢我")

        // 索引也要能重建回来：引用边、悬空边、标签、FTS。
        XCTAssertEqual(try fresh.backlinks(to: target.id).count, 0)
        let plainNote = try XCTUnwrap(fresh.note(id: plain.id))
        XCTAssertTrue(plainNote.body.contains("[[遗忘曲线]]"))
        XCTAssertTrue(try fresh.danglingTargets().contains("遗忘曲线"))
    }

    func testRepairRebuildsIndexesWhenOnlyFlagIsDirty() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "索引过期就重算")
        note.body = "正文提到 [[一个不存在的标题]]。"
        _ = try repo.save(note)

        // 手工清掉索引表，再把标记设为脏：等价于「上次写库写到一半崩了」。
        try repo.db.writer.write { conn in
            try conn.execute(sql: "DELETE FROM link")
            try conn.execute(sql: "DELETE FROM note_fts")
        }
        try repo.setIndexDirty(true)
        XCTAssertTrue(try repo.isIndexDirty())

        let message = try repo.repairFromVaultIfNeeded()
        XCTAssertNotNil(message)
        XCTAssertFalse(try repo.isIndexDirty())
        XCTAssertTrue(try repo.danglingTargets().contains("一个不存在的标题"))
        XCTAssertFalse(try repo.search("正文提到").isEmpty)
    }

    func testEmptyVaultAndEmptyDatabaseIsNotAnError() throws {
        let repo = try makeRepo()
        XCTAssertNil(try repo.repairFromVaultIfNeeded(), "库里没笔记、vault 没文件，无事可做")
    }

    func testLegacyLibraryIsSeededIntoVaultOnce() throws {
        // 老库：笔记只在 sqlite 里，vault 目录还是空的。
        let source = TempVault("legacy-source")
        let db = try AppDatabase.makeInMemory()
        let legacyWriter = source.repo(db)
        var note = try legacyWriter.create(title: "老库里的笔记")
        note.body = "只存在于库里。"
        _ = try legacyWriter.save(note)

        let emptyVault = TempVault("legacy-empty")
        let legacy = emptyVault.repo(db)
        XCTAssertTrue(try legacy.vaultNotesOnDisk().isEmpty)

        let message = try legacy.seedVaultIfNeeded()
        XCTAssertNotNil(message, "库里已有笔记、vault 空时要全量写一份")
        XCTAssertEqual(try legacy.vaultNotesOnDisk().count, 1)
        XCTAssertNil(try legacy.seedVaultIfNeeded(), "目录里已有文件就不再写：判断看目录，不看全局开关")

        // 写完之后删库也能重建
        let fresh = emptyVault.repo(try AppDatabase.makeInMemory())
        XCTAssertNotNil(try fresh.repairFromVaultIfNeeded())
        XCTAssertEqual(try fresh.note(id: note.id)?.body, "只存在于库里。")
    }

    // MARK: - 播种按「当前 vault 目录」判断，不是全局开关

    /// 三篇带正文的笔记写进给定 db + vault，返回 (id, 正文)。
    @discardableResult
    private func makeThreeNotes(_ db: AppDatabase, in target: TempVault) throws -> [(id: String, body: String)] {
        let repo = target.repo(db)
        var made: [(id: String, body: String)] = []
        for index in 1...3 {
            var note = try repo.create(title: "播种第 \(index) 篇")
            note.body = "第 \(index) 篇的正文，带编号 \(index)。"
            _ = try repo.save(note)
            made.append((note.id, note.body))
        }
        return made
    }

    func testSeedsNewVaultAfterVaultPathChanges() throws {
        let vaultA = TempVault("switch-a")
        let vaultB = TempVault("switch-b")
        let db = try AppDatabase.makeInMemory()
        let made = try makeThreeNotes(db, in: vaultA)

        let repoA = vaultA.repo(db)
        XCTAssertNil(try repoA.seedVaultIfNeeded(), "vault A 里已经有文件，不用再播")
        XCTAssertEqual(try repoA.vaultNotesOnDisk().count, 3)

        // 用户把 vault 改到空目录 B，然后重启：同一份库，新的仓库实例。
        let repoB = vaultB.repo(db)
        XCTAssertEqual(try repoB.vaultNotesOnDisk().count, 0, "B 一开始是空的")

        let message = try repoB.seedVaultIfNeeded()
        XCTAssertNotNil(message, "换到空 vault 后必须重新播种，否则 B 永远是空的")
        XCTAssertEqual(try repoB.vaultNotesOnDisk().count, 3, "B 里应有 3 个文件")
        XCTAssertEqual(
            try repoB.vaultNotesOnDisk().map(\.id).sorted(),
            made.map(\.id).sorted(),
            "B 里的就是库里那 3 篇"
        )

        // 再启动一次：目录里已有内容，不再碰。
        XCTAssertNil(try repoB.seedVaultIfNeeded(), "已播种过就返回 nil")
        XCTAssertEqual(try repoB.vaultNotesOnDisk().count, 3)
    }

    func testDeletedDatabaseRecoversFromSecondVault() throws {
        let vaultA = TempVault("recover-a")
        let vaultB = TempVault("recover-b")
        let db = try AppDatabase.makeInMemory()
        let made = try makeThreeNotes(db, in: vaultA)

        XCTAssertNil(try vaultA.repo(db).seedVaultIfNeeded(), "A 已有文件")
        // 切到空 vault B，再启动一次。
        XCTAssertNotNil(try vaultB.repo(db).seedVaultIfNeeded(), "换目录后要重新播种")
        XCTAssertEqual(try vaultB.repo(db).vaultNotesOnDisk().count, 3)

        // 删掉 silvics.sqlite：全新的空库，仍然指向 B。
        let fresh = vaultB.repo(try AppDatabase.makeInMemory())
        XCTAssertEqual(try fresh.vaultNotes().count, 0)

        let message = try fresh.repairFromVaultIfNeeded()
        XCTAssertNotNil(message, "库空、B 有 3 个文件时必须全量导入")
        XCTAssertEqual(try fresh.vaultNotes().count, 3, "从 B 重建应得到 3 篇")
        for want in made {
            XCTAssertEqual(try fresh.note(id: want.id)?.body, want.body, "正文必须一致：\(want.id)")
        }
    }

    func testLegacyVaultSeededFlagDoesNotBlockNewVault() throws {
        let vaultA = TempVault("flag-a")
        let vaultB = TempVault("flag-b")
        let db = try AppDatabase.makeInMemory()
        let made = try makeThreeNotes(db, in: vaultA)

        // vault A 已有文件，这一步不播；把 B 当成「老库升级上来的」：
        // 旧版本写过 meta.vaultSeeded=1，但 B 目录是空的。
        let repoA = vaultA.repo(db)
        XCTAssertNil(try repoA.seedVaultIfNeeded())
        let repoB = vaultB.repo(db)
        try repoB.setMetaValue("vaultSeeded", "1")

        XCTAssertNotNil(try repoB.seedVaultIfNeeded(), "旧开关不能拦住新目录播种")
        XCTAssertEqual(try repoB.vaultNotesOnDisk().count, made.count)
        XCTAssertNil(try repoB.metaValue("vaultSeeded"), "旧键要迁走，不再当开关")
        XCTAssertEqual(try repoB.metaValue("legacyVaultSeeded"), "1", "迁移留痕")
        XCTAssertEqual(try repoB.metaValue("vaultSeededPath"), vaultB.url.path, "记下播到了哪个目录")
    }

    func testEmptyVaultAndEmptyDatabaseKeepsRetrying() throws {
        let emptyVault = TempVault("retry")
        let repo = emptyVault.repo(try AppDatabase.makeInMemory())

        XCTAssertNil(try repo.repairFromVaultIfNeeded())
        XCTAssertNil(
            try repo.repairFromVaultIfNeeded(),
            "库空 + vault 空不能记成「已正常」，下次启动还要再试"
        )

        // 后来 vault 里出现了文件：下一次启动必须导进来。
        let sourceVault = TempVault("retry-source")
        let sourceRepo = sourceVault.repo(try AppDatabase.makeInMemory())
        var note = try sourceRepo.create(title: "后来才出现的笔记")
        note.body = "库和 vault 一开始都是空的。"
        _ = try sourceRepo.save(note)

        try FileManager.default.createDirectory(at: emptyVault.notesURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceVault.fileURL(note.id),
            to: emptyVault.fileURL(note.id)
        )

        XCTAssertNotNil(try repo.repairFromVaultIfNeeded(), "重试时必须把新出现的文件导进来")
        XCTAssertEqual(try repo.note(id: note.id)?.body, "库和 vault 一开始都是空的。")
    }

    // MARK: - 其它写通路也要落文件

    func testRenameAliasAndDismissWriteFiles() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = vault.repo(db)

        let target = try repo.create(title: "间隔重复")
        var plain = try repo.create(title: "旧标题要改成新标题")
        plain.body = "正文提到间隔重复。"
        _ = try repo.save(plain)

        _ = try repo.rename(noteId: plain.id, newTitle: "改名之后要落文件")
        let renamedText = try vault.fileText(plain.id)
        XCTAssertTrue(renamedText.contains("title: 改名之后要落文件"), renamedText)

        XCTAssertNil(try repo.addAlias(noteId: plain.id, name: "别名也要落文件"))
        XCTAssertTrue(try vault.fileText(plain.id).contains("别名也要落文件"))

        let mention = try XCTUnwrap(try repo.mentions(in: plain.id).first)
        try repo.dismissMention(id: mention.id)
        let dismissedText = try vault.fileText(plain.id)
        XCTAssertTrue(dismissedText.contains("dismissed:"), dismissedText)
        XCTAssertTrue(dismissedText.contains(target.id), dismissedText)

        // 三个动作都能在删库后恢复。改名会把旧标题收进别名，所以这里有两个。
        let fresh = vault.repo(try AppDatabase.makeInMemory())
        _ = try fresh.repairFromVaultIfNeeded()
        XCTAssertEqual(try fresh.note(id: plain.id)?.title, "改名之后要落文件")
        XCTAssertEqual(try fresh.aliases(noteId: plain.id).sorted(), ["旧标题要改成新标题", "别名也要落文件"].sorted())
        XCTAssertEqual(try fresh.mentions(in: plain.id).count, 0)
    }
}
