import XCTest
@testable import Silvics

final class ClipSyncTests: XCTestCase {

    private var vault: TempVault!
    private var db: AppDatabase!
    private var repo: GRDBNoteRepository!

    override func setUpWithError() throws {
        vault = TempVault("clip-sync")
        db = try AppDatabase.makeInMemory()
        repo = vault.repo(db)
    }

    override func tearDown() {
        repo = nil
        db = nil
        vault = nil
    }

    private func settings(syncClips: Bool) -> SyncSettings {
        var settings = SyncSettings()
        settings.vaultPath = vault.url.path
        settings.syncClips = syncClips
        return settings
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
        if p.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: out])
        }
        return out
    }

    private func makeBareRepo() throws -> URL {
        let url = vault.url.appendingPathComponent("remote.git", isDirectory: true)
        try git(at: vault.url, ["init", "--bare", "-q", "-b", "main", url.path])
        return url
    }

    private func makeDevice(_ name: String, remote: URL, syncClips: Bool) throws -> (repo: GRDBNoteRepository, sync: VaultSync) {
        let dir = vault.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let deviceRepo = GRDBNoteRepository(db: try AppDatabase.makeInMemory(), vaultURL: dir)
        var settings = SyncSettings()
        settings.vaultPath = dir.path
        settings.remoteURL = remote.path
        settings.authorName = name
        settings.authorEmail = "\(name)@example.com"
        settings.syncClips = syncClips
        return (deviceRepo, VaultSync(repo: deviceRepo, settings: settings))
    }

    private func makeClipAndNote() throws -> (clip: Note, note: Note) {
        let note = try repo.create(title: "间隔重复对抗遗忘")
        var withBody = note
        withBody.body = "参考 [[稀疏重复优于集中突击]]。"
        _ = try repo.save(withBody)
        let clip = try repo.createClip(ClipDraft(
            url: "https://example.com/a",
            title: "稀疏重复优于集中突击",
            sourceTitle: "稀疏重复优于集中突击",
            site: "少数派",
            body: "剪藏正文。",
            tags: ["记忆"],
            aiState: .done
        ))
        return (clip, note)
    }

    func testSyncSettingsDefaultsToSyncingClips() throws {
        let json = #"{"remoteURL":""}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SyncSettings.self, from: json)
        XCTAssertTrue(decoded.syncClips)
    }

    func testExportSkipsClipsWhenDisabled() throws {
        let (clip, _) = try makeClipAndNote()
        // 建剪藏时保存链路已经写过一份文件；清掉它，验证的是「同步导出」这一步。
        let clipsDir = vault.url.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.removeItem(at: clipsDir)

        let sync = VaultSync(repo: repo, settings: settings(syncClips: false))
        let written = try sync.exportAll()

        let files = (try? FileManager.default.contentsOfDirectory(atPath: clipsDir.path)) ?? []
        XCTAssertTrue(files.filter { $0.hasSuffix(".md") }.isEmpty)
        XCTAssertEqual(written, 1, "只写出概念笔记")
        XCTAssertNotNil(try repo.clip(id: clip.id))
    }

    func testExportWritesClipsWhenEnabled() throws {
        let (clip, _) = try makeClipAndNote()
        let sync = VaultSync(repo: repo, settings: settings(syncClips: true))
        _ = try sync.exportAll()

        let file = vault.url
            .appendingPathComponent("clips", isDirectory: true)
            .appendingPathComponent(VaultFormat.fileName(for: clip.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testManifestHashCoversClipMetadata() throws {
        let (clip, _) = try makeClipAndNote()
        let sync = VaultSync(repo: repo, settings: settings(syncClips: true))
        _ = try sync.exportAll()

        let manifestURL = vault.url.appendingPathComponent(VaultFormat.manifestName)
        let first = try XCTUnwrap(VaultFormat.decodeManifest(try Data(contentsOf: manifestURL)))
        XCTAssertEqual(first.schema, VaultFormat.manifestSchema)

        _ = try repo.updateClipStatus(id: clip.id, status: .read)
        _ = try sync.exportAll()
        let second = try XCTUnwrap(VaultFormat.decodeManifest(try Data(contentsOf: manifestURL)))
        let before = first.notes.first { $0.id == clip.id }
        let after = second.notes.first { $0.id == clip.id }
        XCTAssertNotEqual(before?.hash, after?.hash, "只改阅读状态，manifest 哈希也要变")
    }

    func testExportMarkdownKeepsFrontmatterAndTags() throws {
        let (clip, _) = try makeClipAndNote()
        let note = try XCTUnwrap(try repo.clip(id: clip.id))
        let text = ClipExport.markdown(note)
        XCTAssertTrue(text.contains("type: clip"))
        XCTAssertTrue(text.contains("tags:"))
        XCTAssertTrue(text.contains("  - 记忆"))
        XCTAssertTrue(text.contains("clip:"))
        XCTAssertTrue(text.contains("url: https://example.com/a"))
    }

    func testImportAllSkipsClipsWhenDisabled() throws {
        let (clip, _) = try makeClipAndNote()
        // 模拟「vault 里有剪藏、库里没有」：导出后直接删库里的剪藏，再从 vault 恢复。
        let syncEnabled = VaultSync(repo: repo, settings: settings(syncClips: true))
        _ = try syncEnabled.exportAll()
        try repo.delete(id: clip.id)
        XCTAssertNil(try repo.clip(id: clip.id))

        let syncDisabled = VaultSync(repo: repo, settings: settings(syncClips: false))
        let report = try syncDisabled.importAll()
        XCTAssertEqual(report.inserted, 0)
        XCTAssertNil(try repo.clip(id: clip.id), "关掉同步剪藏时，从 vault 恢复也不能拉回剪藏")

        let syncOn = VaultSync(repo: repo, settings: settings(syncClips: true))
        _ = try syncOn.importAll()
        XCTAssertNotNil(try repo.clip(id: clip.id))
    }

    func testVerifyIgnoresClipFilesWhenDisabled() throws {
        try makeClipAndNote()
        let sync = VaultSync(repo: repo, settings: settings(syncClips: false))
        _ = try sync.exportAll()

        // clips/ 里仍有剪藏文件（保存链路写的），关闭同步时 verify 不能把它报成「不在 manifest 里」。
        let result = try sync.verify()
        XCTAssertFalse(
            result.problems.contains { $0.contains("不在 manifest") },
            "关闭同步剪藏后，遗留的剪藏文件不应算漂移：\(result.problems)"
        )
    }

    func testGitStageExcludesClipsWhenDisabled() throws {
        let git = GitClient(workDir: vault.url, authorName: "test", authorEmail: "test@localhost")
        try git.run(["init", "-q"])
        _ = try repo.create(title: "间隔重复对抗遗忘")
        try git.stageAll()
        try git.commit("init")
        let clipsDir = vault.url.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        try "剪藏".write(to: clipsDir.appendingPathComponent("x.md"), atomically: true, encoding: .utf8)

        XCTAssertTrue(git.hasLocalChanges())
        XCTAssertFalse(git.hasLocalChanges(excluding: ["clips"]), "只有剪藏变化时不应触发提交")

        try git.stageAll(excluding: ["clips"])
        XCTAssertFalse(git.stagedChangesExist(), "剪藏不能进暂存区")
    }

    func testClipRenameAllowsDateLikeLongTitle() throws {
        let (clip, _) = try makeClipAndNote()
        let longDateTitle = "2026-11-24 的剪藏：间隔重复为什么有效以及它和生活的关系"
        XCTAssertNoThrow(try repo.rename(noteId: clip.id, newTitle: longDateTitle))
        XCTAssertEqual(try repo.clip(id: clip.id)?.title, longDateTitle)
    }

    func testResetAllClearsClipSettings() throws {
        let suite = "clip-reset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let previousClipDefaults = ClipSettings.defaults
        ClipSettings.defaults = defaults
        defer {
            ClipSettings.defaults = previousClipDefaults
            defaults.removePersistentDomain(forName: suite)
        }

        var settings = ClipSettings()
        settings.autoSummarize = false
        settings.save()
        XCTAssertFalse(ClipSettings.load().autoSummarize)

        let providerDefaults = UserDefaults(suiteName: "provider-\(UUID().uuidString)")!
        let service = ProviderService(secrets: InMemorySecretStore(), defaults: providerDefaults)
        service.resetAll(alsoAppearance: true)

        XCTAssertTrue(ClipSettings.load().autoSummarize, "全局恢复要清剪藏设置")
    }

    @MainActor
    func testDeletingClipRemovesVaultFileAndDoesNotResurrect() throws {
        let clip = try repo.createClip(ClipDraft(
            url: "https://example.com/delete-me",
            title: "要删掉的剪藏",
            body: "正文。"
        ))
        let file = vault.url
            .appendingPathComponent(VaultFormat.noteDir(for: NoteTypes.clipID), isDirectory: true)
            .appendingPathComponent(VaultFormat.fileName(for: clip.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let app = AppState(repo: repo)
        app.deleteClip(id: clip.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "删除剪藏要同步删 vault 文件")
        XCTAssertNil(try repo.clip(id: clip.id))
        _ = try VaultSync(repo: repo, settings: settings(syncClips: true)).importAll()
        XCTAssertNil(try repo.clip(id: clip.id), "从 vault 恢复不能把删掉的剪藏拉回来")
    }

    func testVerifyRightAfterDisablingClipsDoesNotReportCountMismatch() throws {
        try makeClipAndNote()
        // 先在开启状态导出一次，manifest 里含剪藏。
        _ = try VaultSync(repo: repo, settings: settings(syncClips: true)).exportAll()

        // 直接关掉开关，不重新导出，立刻校验。
        let disabled = VaultSync(repo: repo, settings: settings(syncClips: false))
        let result = try disabled.verify()
        XCTAssertFalse(
            result.problems.contains { $0.contains("篇，vault 里") },
            "关闭同步剪藏后不应因 manifest 里还留着剪藏而报篇数不一致：\(result.problems)"
        )
    }

    func testBehindMergeNeverCommitsClipsWhenDisabled() throws {
        let remote = try makeBareRepo()
        let a = try makeDevice("device-a", remote: remote, syncClips: true)
        let b = try makeDevice("device-b", remote: remote, syncClips: false)

        _ = try a.repo.create(title: "第一篇来自 A 的笔记")
        _ = try a.sync.sync()
        _ = try b.sync.sync()

        // A 再推一篇，让 B 处于落后状态，进入合并分支。
        _ = try a.repo.create(title: "第二篇来自 A 的笔记")
        _ = try a.sync.sync()

        // B 本地有一篇剪藏（关闭同步后仍然会写 clips/）。
        _ = try b.repo.createClip(ClipDraft(
            url: "https://example.com/local-only",
            title: "只应留在本机的剪藏",
            body: "这段正文不该被推到远端。"
        ))
        _ = try b.sync.sync()

        let tree = try git(at: remote, ["ls-tree", "-r", "--name-only", "main"])
        XCTAssertFalse(tree.contains("clips/"), "关闭同步剪藏时，落后合并也不能把 clips/ 提交推送。实际：\(tree)")
        XCTAssertEqual(try b.repo.clipSummaries().count, 1, "剪藏要留在本机")
    }

    func testExportAllWritesOneFilePerClip() throws {
        try makeClipAndNote()
        let dir = vault.url.appendingPathComponent("export", isDirectory: true)
        let count = try VaultSync(repo: repo, settings: settings(syncClips: true)).exportAll()
        XCTAssertGreaterThan(count, 0)

        let note = try XCTUnwrap(try repo.clipSummaries().first)
        let url = try ClipExport.write(try XCTUnwrap(try repo.clip(id: note.id)), to: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
