import XCTest
@testable import Silvics

/// 用本机 bare 仓库模拟远端，两个 vault 目录模拟两台设备。
final class GitSyncTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("silvics-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBareRepo() throws -> URL {
        let url = root.appendingPathComponent("remote.git", isDirectory: true)
        try git(at: root, ["init", "--bare", "-q", "-b", "main", url.path])
        return url
    }

    @discardableResult
    private func git(at dir: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_AUTHOR_NAME"] = "测试"
        env["GIT_AUTHOR_EMAIL"] = "t@example.com"
        env["GIT_COMMITTER_NAME"] = "测试"
        env["GIT_COMMITTER_EMAIL"] = "t@example.com"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 { throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: out]) }
        return out
    }

    /// 一台「设备」：自己的库 + 自己的 vault 目录。
    private func makeDevice(_ name: String, remote: URL) throws -> (repo: GRDBNoteRepository, sync: VaultSync) {
        // 一台设备一套目录：仓库写文件与同步导出的必须是同一个 vault。
        let deviceVault = root.appendingPathComponent(name, isDirectory: true)
        let repo = GRDBNoteRepository(db: try AppDatabase.makeInMemory(), vaultURL: deviceVault)
        var settings = SyncSettings()
        settings.vaultPath = deviceVault.path
        settings.remoteURL = remote.path
        settings.authorName = name
        settings.authorEmail = "\(name)@example.com"
        return (repo, VaultSync(repo: repo, settings: settings))
    }

    func testFirstSyncPushesAndSecondDevicePulls() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        let note = try a.repo.create(title: "笔记需要培育不需要归档")
        var body = note
        body.body = "这是 A 写的正文。"
        _ = try a.repo.save(body)

        let reportA = try a.sync.sync()
        XCTAssertTrue(reportA.pushed, reportA.summary)

        let b = try makeDevice("device-b", remote: remote)
        let reportB = try b.sync.sync()
        XCTAssertEqual(reportB.importedNotes, 1, reportB.summary)

        let pulled = try b.repo.note(id: note.id)
        XCTAssertEqual(pulled?.body, "这是 A 写的正文。")
        XCTAssertEqual(try b.repo.summaries().count, 1)
    }

    func testEditOnOneSideReachesOther() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        let note = try a.repo.create(title: "稀疏重复优于集中突击")
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()

        var edited = try a.repo.note(id: note.id)!
        edited.body = "A 追加的一段。"
        _ = try a.repo.save(edited)
        _ = try a.sync.sync()

        let reportB = try b.sync.sync()
        XCTAssertEqual(reportB.importedNotes, 1, reportB.summary)
        XCTAssertEqual(try b.repo.note(id: note.id)?.body, "A 追加的一段。")
    }

    func testDisjointEditsMergeCleanly() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        let note = try a.repo.create(title: "标题即接口")
        var seeded = note
        seeded.body = "第一行\n第二行\n第三行"
        _ = try a.repo.save(seeded)
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()

        // A 改最后一行
        var fromA = try a.repo.note(id: note.id)!
        fromA.body = "第一行\n第二行\n第三行由 A 改写"
        _ = try a.repo.save(fromA)
        _ = try a.sync.sync()

        // B 改第一行
        var fromB = try b.repo.note(id: note.id)!
        fromB.body = "第一行由 B 改写\n第二行\n第三行"
        _ = try b.repo.save(fromB)
        let reportB = try b.sync.sync()
        XCTAssertTrue(reportB.conflicts.isEmpty, reportB.conflicts.joined(separator: " / "))

        let merged = try b.repo.note(id: note.id)?.body
        XCTAssertEqual(merged, "第一行由 B 改写\n第二行\n第三行由 A 改写")

        // A 再拉一次，应该拿到同一份合并结果
        _ = try a.sync.sync()
        XCTAssertEqual(try a.repo.note(id: note.id)?.body, merged)
    }

    func testSameLineConflictKeepsLocalAndArchives() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        let note = try a.repo.create(title: "冲突要留档")
        var seeded = note
        seeded.body = "同一行"
        _ = try a.repo.save(seeded)
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()

        var fromA = try a.repo.note(id: note.id)!
        fromA.body = "A 的版本"
        _ = try a.repo.save(fromA)
        _ = try a.sync.sync()

        var fromB = try b.repo.note(id: note.id)!
        fromB.body = "B 的版本"
        _ = try b.repo.save(fromB)
        let reportB = try b.sync.sync()

        XCTAssertEqual(reportB.conflicts.count, 1, reportB.summary)
        XCTAssertEqual(try b.repo.note(id: note.id)?.body, "B 的版本", "冲突时保留本地")

        let conflicts = (try? FileManager.default.contentsOfDirectory(atPath: b.sync.conflictsURL.path)) ?? []
        XCTAssertEqual(conflicts.count, 2, "远端与本地两份原文都要留档")
        let archived = try conflicts.map {
            try String(contentsOf: b.sync.conflictsURL.appendingPathComponent($0), encoding: .utf8)
        }
        XCTAssertTrue(archived.contains { $0.contains("A 的版本") }, "远端版本必须留档")
        XCTAssertTrue(archived.contains { $0.contains("B 的版本") })
    }

    func testRemoteDeletionRemovesUnchangedLocalNote() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        let note = try a.repo.create(title: "这条要被删掉")
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()
        XCTAssertNotNil(try b.repo.note(id: note.id))

        try a.repo.delete(id: note.id)
        try a.sync.removeFromVault(id: note.id)
        _ = try a.sync.sync()

        let reportB = try b.sync.sync()
        XCTAssertEqual(reportB.removedNotes, 1, reportB.summary)
        XCTAssertNil(try b.repo.note(id: note.id))
    }

    func testEmptyDatabaseIsRestoredBySync() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        let note = try a.repo.create(title: "库丢了也要能回来")
        var seeded = note
        seeded.body = "这段正文只能从 vault 找回来。"
        _ = try a.repo.save(seeded)
        _ = try a.sync.sync()

        // 同一台机器：库被清空，vault 与仓库都还在
        let wiped = GRDBNoteRepository(
            db: try AppDatabase.makeInMemory(),
            vaultURL: URL(fileURLWithPath: a.sync.settings.vaultPath, isDirectory: true)
        )
        var settings = SyncSettings()
        settings.vaultPath = a.sync.settings.vaultPath
        settings.remoteURL = remote.path
        let restored = VaultSync(repo: wiped, settings: settings)

        let report = try restored.sync()
        XCTAssertEqual(report.importedNotes, 1, report.summary)
        XCTAssertEqual(try wiped.note(id: note.id)?.body, "这段正文只能从 vault 找回来。")
    }

    func testConcurrentPushIsRetried() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        _ = try a.repo.create(title: "并发的第一台")
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()

        // 两台各自新增，A 先推，B 后推必然被拒
        _ = try a.repo.create(title: "A 新增的一条")
        _ = try a.sync.sync()
        _ = try b.repo.create(title: "B 新增的一条")

        let reportB = try b.sync.sync()
        XCTAssertTrue(reportB.pushed, reportB.summary)

        _ = try a.sync.sync()
        XCTAssertEqual(try a.repo.summaries().count, 3)
        XCTAssertEqual(try b.repo.summaries().count, 3)
    }

    // MARK: - P0-2 远端 frontmatter 改动必须拉进来

    func testRemoteJournalMetaChangeArrivesWithoutBodyChange() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        var note = try a.repo.create(title: "2026-11-24")
        note.type = NoteTypes.journalID
        note.setMetaFields(["date": "2026-11-24", "carryFrom": "2026-11-23"])
        note.body = "今天的日记。"
        _ = try a.repo.save(note)
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()
        XCTAssertEqual(try b.repo.note(id: note.id)?.metaFields["carryFrom"], "2026-11-23")

        // A 只改 `journal.carryFrom`，正文一个字节没动
        var changed = try a.repo.note(id: note.id)!
        changed.setMetaFields(["date": "2026-11-24", "carryFrom": "2026-11-20"])
        _ = try a.repo.save(changed)
        _ = try a.sync.sync()

        let reportB = try b.sync.sync()
        XCTAssertEqual(
            try b.repo.note(id: note.id)?.metaFields["carryFrom"],
            "2026-11-20",
            "远端只改 frontmatter 也要拉进来；\(reportB.summary)"
        )
        XCTAssertTrue(reportB.conflicts.isEmpty, reportB.conflicts.joined(separator: " / "))
        XCTAssertEqual(try b.repo.note(id: note.id)?.body, "今天的日记。")
    }

    func testUnknownExtraKeyFromOneSideIsMerged() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        let note = try a.repo.create(title: "未知键要能合过来")
        var seeded = note
        seeded.body = "正文不动。"
        _ = try a.repo.save(seeded)
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()

        // A 只新增未知键
        var fromA = try a.repo.note(id: note.id)!
        var extraA = fromA.frontmatterExtra
        extraA.scalars["futureScalar"] = "远端写的"
        extraA.lists["futureList"] = ["一", "二"]
        extraA.sections["futureSection"] = ["alpha": "1"]
        fromA.setFrontmatterExtra(extraA)
        _ = try a.repo.save(fromA)
        _ = try a.sync.sync()

        _ = try b.sync.sync()
        let mergedB = try b.repo.note(id: note.id)!.frontmatterExtra
        XCTAssertEqual(mergedB.scalars["futureScalar"], "远端写的")
        XCTAssertEqual(mergedB.lists["futureList"], ["一", "二"])
        XCTAssertEqual(mergedB.sections["futureSection"], ["alpha": "1"])

        // B 再加一个不同的键，也要能回到 A
        var fromB = try b.repo.note(id: note.id)!
        var extraB = fromB.frontmatterExtra
        extraB.scalars["bOnly"] = "本机写的"
        fromB.setFrontmatterExtra(extraB)
        _ = try b.repo.save(fromB)
        _ = try b.sync.sync()
        _ = try a.sync.sync()

        let mergedA = try a.repo.note(id: note.id)!.frontmatterExtra
        XCTAssertEqual(mergedA.scalars["bOnly"], "本机写的")
        XCTAssertEqual(mergedA.scalars["futureScalar"], "远端写的")
    }

    func testConflictingMetaValuesAreArchived() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        var note = try a.repo.create(title: "2026-11-25")
        note.type = NoteTypes.journalID
        note.setMetaFields(["date": "2026-11-25", "carryFrom": "2026-11-24"])
        _ = try a.repo.save(note)
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()

        var fromA = try a.repo.note(id: note.id)!
        fromA.setMetaFields(["date": "2026-11-25", "carryFrom": "2026-11-20"])
        _ = try a.repo.save(fromA)
        _ = try a.sync.sync()

        var fromB = try b.repo.note(id: note.id)!
        fromB.setMetaFields(["date": "2026-11-25", "carryFrom": "2026-11-22"])
        _ = try b.repo.save(fromB)
        let reportB = try b.sync.sync()

        XCTAssertTrue(
            reportB.conflicts.contains { $0.contains("carryFrom") },
            reportB.conflicts.joined(separator: " / ")
        )
        XCTAssertEqual(
            try b.repo.note(id: note.id)?.metaFields["carryFrom"],
            "2026-11-22",
            "两边都改同一个键时保留本机值"
        )

        let archived = (try? FileManager.default.contentsOfDirectory(atPath: b.sync.conflictsURL.path)) ?? []
        XCTAssertEqual(archived.count, 2, "远端与本机两份原文都要留档")
        let texts = try archived.map {
            try String(contentsOf: b.sync.conflictsURL.appendingPathComponent($0), encoding: .utf8)
        }
        XCTAssertTrue(texts.contains { $0.contains("carryFrom: 2026-11-20") }, "远端值必须留档")
        XCTAssertTrue(texts.contains { $0.contains("carryFrom: 2026-11-22") })
    }

    func testConflictingTypeIsNotAutoSelected() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        let note = try a.repo.create(title: "类型冲突不自动选")
        var seeded = note
        seeded.body = "同一段正文。"
        _ = try a.repo.save(seeded)
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()

        var fromA = try a.repo.note(id: note.id)!
        fromA.type = NoteTypes.journalID
        fromA.setMetaFields(["date": "2026-11-26"])
        _ = try a.repo.save(fromA)
        _ = try a.sync.sync()

        let reportB = try b.sync.sync()
        XCTAssertTrue(
            reportB.conflicts.contains { $0.contains("type") },
            reportB.conflicts.joined(separator: " / ")
        )
        XCTAssertEqual(
            try b.repo.note(id: note.id)?.type,
            NoteTypes.noteID,
            "type 两边不同不能自动选"
        )
        let archived = (try? FileManager.default.contentsOfDirectory(atPath: b.sync.conflictsURL.path)) ?? []
        XCTAssertEqual(archived.count, 2, "两份原文都要留档")
    }

    func testRemoteTitleChangeArrivesWhenLocalUnchanged() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote)
        let note = try a.repo.create(title: "标题会改也要同步")
        var seeded = note
        seeded.body = "正文不动。"
        _ = try a.repo.save(seeded)
        _ = try a.sync.sync()

        let b = try makeDevice("device-b", remote: remote)
        _ = try b.sync.sync()

        var fromA = try a.repo.note(id: note.id)!
        fromA.title = "标题在远端改过了"
        _ = try a.repo.save(fromA)
        _ = try a.sync.sync()

        _ = try b.sync.sync()
        XCTAssertEqual(try b.repo.note(id: note.id)?.title, "标题在远端改过了")
    }
}
