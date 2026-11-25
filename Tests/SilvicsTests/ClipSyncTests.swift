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
