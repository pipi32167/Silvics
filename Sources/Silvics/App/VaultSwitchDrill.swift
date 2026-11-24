#if DEBUG
import Foundation

/// 仅 DEBUG：`SILVICS_VAULT_SWITCH_DRILL=<dir>` + `SILVICS_DRILL_STEP=write|switch|rebuild`。
///
/// 演练「换 vault 目录后还能不能播种」，三次启动，中间由 shell 删库：
/// 1. `write`：临时库写 3 篇，vault A 里落 3 个文件；跑一遍启动自愈，打印条数与文件数。
/// 2. `switch`：同一份库，vault 改成空的 B；跑启动自愈，B 应出现 3 个文件。
/// 3. `rebuild`：`rm silvics.sqlite` 后启动，从 B 全量重建，逐篇比对标题与正文。
///
/// 走真实的 `AppDatabase` + `GRDBNoteRepository`，没有测试替身。任一步对不上退出码 2。
enum VaultSwitchDrill {

    private static let titles = ["第一篇：间隔重复", "第二篇：稀疏重复", "第三篇：遗忘曲线"]

    private static func body(_ index: Int) -> String {
        "第 \(index) 篇的正文，带编号 \(index)。"
    }

    static func runIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SILVICS_VAULT_SWITCH_DRILL"],
              !raw.isEmpty else { return }
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        let step = ProcessInfo.processInfo.environment["SILVICS_DRILL_STEP"] ?? "write"
        exit(run(root: root, step: step))
    }

    private static func run(root: URL, step: String) -> Int32 {
        let fm = FileManager.default
        let dbURL = root.appendingPathComponent("silvics.sqlite")
        let vaultA = root.appendingPathComponent("vault-a", isDirectory: true)
        let vaultB = root.appendingPathComponent("vault-b", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            switch step {
            case "write": return try write(dbURL: dbURL, vault: vaultA)
            case "switch": return try switchVault(dbURL: dbURL, to: vaultB)
            case "rebuild": return try rebuild(dbURL: dbURL, vault: vaultB)
            default:
                print("[drill] 未知步骤 \(step)，只认 write / switch / rebuild")
                return 2
            }
        } catch {
            print("[drill] 失败：\(error)")
            return 2
        }
    }

    // MARK: - 步骤 1：临时库 3 篇 + vault A

    private static func write(dbURL: URL, vault: URL) throws -> Int32 {
        // 先在临时目录里写 3 篇（模拟「老库，笔记只在 sqlite + 旧目录」），
        // 再把 vault 指向空目录 A，让 `seedVaultIfNeeded` 真正播一次种。
        let origin = vault.deletingLastPathComponent().appendingPathComponent("origin-vault", isDirectory: true)
        let originRepo = GRDBNoteRepository(db: try AppDatabase.makeOnDisk(at: dbURL), vaultURL: origin)
        print("[drill] 步骤 1：写库 \(dbURL.path)，先在 \(origin.path) 落文件")

        for (offset, title) in titles.enumerated() {
            let index = offset + 1
            var note = try originRepo.create(title: title)
            note.body = body(index)
            _ = try originRepo.save(note)
        }
        print("[drill] 写入后：库里 \(try noteCount(originRepo)) 篇，origin notes/ \(fileCount(origin)) 个文件")
        print("[drill] 此时：vault A notes/ \(fileCount(vault)) 个文件（空的，等着播种）")

        let repo = GRDBNoteRepository(db: try AppDatabase.makeOnDisk(at: dbURL), vaultURL: vault)
        let seeded = try repo.seedVaultIfNeeded()
        print("[drill] seedVaultIfNeeded → \(seeded ?? "nil（没播种，这是缺陷）")")
        let repaired = try repo.repairFromVaultIfNeeded()
        print("[drill] repairFromVaultIfNeeded → \(repaired ?? "nil（无事可做）")")
        print("[drill] 播种后：库里 \(try noteCount(repo)) 篇，vault A notes/ \(fileCount(vault)) 个文件")

        // 再启动一次：目录里已有文件，应该什么都不写。
        let again = try repo.seedVaultIfNeeded()
        print("[drill] 再启动一次 seedVaultIfNeeded → \(again ?? "nil（已播种，不重复写）")")
        return fileCount(vault) == titles.count ? 0 : 2
    }

    // MARK: - 步骤 2：切到空 vault B

    private static func switchVault(dbURL: URL, to vault: URL) throws -> Int32 {
        let repo = GRDBNoteRepository(db: try AppDatabase.makeOnDisk(at: dbURL), vaultURL: vault)
        print("[drill] 步骤 2：同一份库，vault 换成 B \(vault.path)")
        print("[drill] 切换前：库里 \(try noteCount(repo)) 篇，vault B notes/ \(fileCount(vault)) 个文件")

        let seeded = try repo.seedVaultIfNeeded()
        print("[drill] seedVaultIfNeeded → \(seeded ?? "nil（没播种，这是缺陷）")")
        let repaired = try repo.repairFromVaultIfNeeded()
        print("[drill] repairFromVaultIfNeeded → \(repaired ?? "nil（无事可做）")")
        let files = fileCount(vault)
        print("[drill] 切换后：vault B notes/ \(files) 个文件")
        return files == titles.count ? 0 : 2
    }

    // MARK: - 步骤 3：删库后从 B 重建

    private static func rebuild(dbURL: URL, vault: URL) throws -> Int32 {
        let repo = GRDBNoteRepository(db: try AppDatabase.makeOnDisk(at: dbURL), vaultURL: vault)
        print("[drill] 步骤 3：库已删除，重新打开空库 \(dbURL.path)")
        print("[drill] 启动前：库里 \(try noteCount(repo)) 篇，vault B notes/ \(fileCount(vault)) 个文件")

        let repaired = try repo.repairFromVaultIfNeeded()
        print("[drill] repairFromVaultIfNeeded → \(repaired ?? "nil（没有重建，这是缺陷）")")

        let notes = try repo.vaultNotes()
        print("[drill] 重建后：库里 \(notes.count) 篇，期望 \(titles.count) 篇")

        var failures = 0
        for (offset, title) in titles.enumerated() {
            let index = offset + 1
            guard let got = notes.first(where: { $0.title == title }) else {
                print("[drill] ✗ 《\(title)》没重建出来")
                failures += 1
                continue
            }
            let bodyOK = got.body == body(index)
            if !bodyOK { failures += 1 }
            print("[drill] \(bodyOK ? "✓" : "✗") 《\(got.title)》正文\(bodyOK ? "一致" : "不一致：\(got.body)")")
        }

        if failures == 0 {
            print("[drill] 结论：换目录播种 + 删库后从 B 重建，3 篇正文全一致")
            return 0
        }
        print("[drill] 结论：有 \(failures) 处不一致")
        return 2
    }

    // MARK: - 小工具

    private static func noteCount(_ repo: GRDBNoteRepository) throws -> Int {
        try repo.summaries().count
    }

    private static func fileCount(_ vault: URL) -> Int {
        let dir = vault.appendingPathComponent(VaultFormat.notesDir, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.count
    }
}
#endif
