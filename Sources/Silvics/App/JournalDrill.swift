#if DEBUG
import Foundation

/// 仅 DEBUG：`SILVICS_JOURNAL_DRILL=<dir>` 跑模板 + 承接的命令行演练。
///
/// 临时库 + 临时 vault：写两份模板 → 建 11-21 日记（2 条未完成）→ 建 11-24 日记。
/// 打印两篇的文件路径与 11-24 的正文，验证承接生效、文件落在 `journal/`。
/// 走真实的 `AppDatabase` + `GRDBNoteRepository` + `VaultSync`，没有测试替身。对不上退出码 2。
enum JournalDrill {

    static func runIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SILVICS_JOURNAL_DRILL"], !raw.isEmpty else { return }
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        exit(run(root: root))
    }

    private static func run(root: URL) -> Int32 {
        do {
            let fm = FileManager.default
            let vault = root.appendingPathComponent("vault", isDirectory: true)
            let mirror = root.appendingPathComponent("vault-export", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: vault, withIntermediateDirectories: true)

            let repo = GRDBNoteRepository(
                db: try AppDatabase.makeOnDisk(at: root.appendingPathComponent("silvics.sqlite")),
                vaultURL: vault
            )
            try fm.createDirectory(
                at: vault.appendingPathComponent(VaultFormat.templatesDir, isDirectory: true),
                withIntermediateDirectories: true
            )
            try writeTemplate(name: "工作", order: 1, in: vault)
            try writeTemplate(name: "生活", order: 2, in: vault)
            print("[drill] 临时库 \(root.path)/silvics.sqlite，临时 vault \(vault.path)")
            print("[drill] 模板：templates/工作.md（order 1）、templates/生活.md（order 2）")

            var first = try repo.journalNote(on: "2026-11-21", using: ["工作", "生活"])
            first.body = """
            ## 工作
            - [ ] 把保存链路倒过来
            - [x] 已经做完的一件事
            ## 生活
            - [ ] 买咖啡豆
            """
            first = try repo.save(first)

            let second = try repo.journalNote(on: "2026-11-24", using: ["工作", "生活"])

            let firstPath = repo.vaultFileURL(for: first.id, type: first.type).path
            let secondPath = repo.vaultFileURL(for: second.id, type: second.type).path
            print("[drill] 11-21 文件：\(firstPath)")
            print("[drill] 11-24 文件：\(secondPath)")
            print("[drill] 11-24 id=\(second.id) type=\(second.type) meta=\(second.metaFields)")
            print("[drill] 11-24 正文：")
            for line in second.body.components(separatedBy: "\n") { print("[drill]   | \(line)") }

            var settings = SyncSettings()
            settings.vaultPath = mirror.path
            try VaultSync(repo: repo, settings: settings).exportAll()
            let exported = mirror.appendingPathComponent("journal/2026-11-24.md").path
            print("[drill] 导出副本：\(exported)")

            var failures = 0
            func check(_ ok: Bool, _ label: String) {
                print("[drill] \(ok ? "✓" : "✗") \(label)")
                if !ok { failures += 1 }
            }

            check(firstPath.hasSuffix("/journal/2026-11-21.md"), "11-21 落在 journal/2026-11-21.md")
            check(secondPath.hasSuffix("/journal/2026-11-24.md"), "11-24 落在 journal/2026-11-24.md")
            check(
                !fm.fileExists(atPath: vault.appendingPathComponent("notes/2026-11-24.md").path),
                "notes/ 里没有 2026-11-24.md"
            )
            check(second.body.hasPrefix("## 承接（来自 11-21）"), "承接段插在正文最前，来源是 11-21")
            let carried = second.body.components(separatedBy: "\n").filter { $0.hasPrefix("- [ ] ") }
            check(carried == ["- [ ] 把保存链路倒过来", "- [ ] 买咖啡豆"], "承接 2 条未完成：\(carried)")
            check(second.body.contains("## 工作\n\n## 生活\n"), "模板按 order 拼成骨架")
            check(second.metaFields["carryFrom"] == "2026-11-21", "frontmatter 记了 carryFrom")
            check(fm.fileExists(atPath: exported), "导出副本也在 journal/ 下")

            print("[drill] 结论：\(failures == 0 ? "承接 + 模板 + journal/ 落盘全部符合预期" : "有 \(failures) 项不符")")
            return failures == 0 ? 0 : 2
        } catch {
            print("[drill] 失败：\(error)")
            return 2
        }
    }

    private static func writeTemplate(name: String, order: Int, in vault: URL) throws {
        let text = """
        ---
        template:
          name: \(name)
          order: \(order)
        ---
        """
        try text.write(
            to: vault.appendingPathComponent("\(VaultFormat.templatesDir)/\(name).md"),
            atomically: true,
            encoding: .utf8
        )
    }
}
#endif
