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
