#if DEBUG
import Foundation

/// 仅 DEBUG：`SILVICS_INVERT_DRILL=<dir>` 保存链路倒转的命令行演练。
///
/// 两次启动，中间由 shell 删库：
/// 1. 第一次（目录里没有 `silvics.sqlite`）：写入 3 篇（普通 / 日记 / 带未知键），
///    把期望字段落成 `expected.json`，打印每篇路径。
/// 2. `rm silvics.sqlite`，再启动：启动自愈从 vault 全量导入，逐字段比对并打印结果。
///
/// 有差异退出码 2，全对退出码 0。走的是真实的 `NoteStore` + `NoteWriter`，不是测试替身。
enum InvertDrill {

    /// 期望的字段快照。比对时逐项打印 OK/DIFF。
    struct Snapshot: Codable {
        var id: String
        var title: String
        var type: String
        var status: String
        var body: String
        var aliases: [String]
        var dismissed: [String]
        var meta: [String: String]
        var extraScalars: [String: String]
        var extraLists: [String: [String]]
        var extraSections: [String: [String: String]]
    }

    static func runIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SILVICS_INVERT_DRILL"], !raw.isEmpty else {
            return
        }
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        let code = run(root: root)
        exit(code)
    }

    private static func run(root: URL) -> Int32 {
        let fm = FileManager.default
        let dbURL = root.appendingPathComponent("silvics.sqlite")
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        let expectedURL = root.appendingPathComponent("expected.json")
        let isRebuild = !fm.fileExists(atPath: dbURL.path) && fm.fileExists(atPath: expectedURL.path)

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if isRebuild {
                return try rebuild(root: root, dbURL: dbURL, vault: vault, expectedURL: expectedURL)
            }
            return try write(dbURL: dbURL, vault: vault, expectedURL: expectedURL)
        } catch {
            print("[drill] 失败：\(error)")
            return 2
        }
    }

    // MARK: - 第一遍：写入

    private static func write(dbURL: URL, vault: URL, expectedURL: URL) throws -> Int32 {
        let fm = FileManager.default
        if fm.fileExists(atPath: dbURL.path) { try fm.removeItem(at: dbURL) }
        try? fm.removeItem(at: vault)

        let db = try AppDatabase.makeOnDisk(at: dbURL)
        let repo = GRDBNoteRepository(db: db, vaultURL: vault)
        print("[drill] 写库 \(dbURL.path)")
        print("[drill] 写 vault \(vault.path)")

        // 1. 普通笔记：带引用、别名、被忽略的提及。
        let target = try repo.create(title: "间隔重复")
        var targetNote = target
        targetNote.body = "间隔重复优于集中突击。"
        _ = try repo.save(targetNote)

        var plain = try repo.create(title: "稀疏重复优于集中突击")
        plain.body = "第一段：写作工具的核心指标是每次开口的摩擦。\n\n第二段提到间隔重复，还有 [[遗忘曲线]]。"
        _ = try repo.save(plain)
        _ = try repo.addAlias(noteId: plain.id, name: "间隔复习的威力")
        if let mention = try repo.mentions(in: plain.id).first {
            try repo.dismissMention(id: mention.id)
            print("[drill] 忽略提及 \(mention.targetTitle)（note \(plain.id)）")
        }

        // 2. 日记：type + 类型段。
        var journal = try repo.create(title: "2026-11-24")
        journal.type = NoteTypes.journalID
        journal.setMetaFields(["date": "2026-11-24", "carryFrom": "2026-11-23"])
        journal.body = "## 工作\n- [ ] 把保存链路倒过来\n"
        _ = try repo.save(journal)

        // 3. 带未知 frontmatter 键的笔记。
        var unknown = try repo.create(title: "未知键要原样保留")
        var extra = VaultFormat.FrontmatterExtra()
        extra.scalars["futureScalar"] = "别丢我"
        extra.lists["futureList"] = ["甲", "乙"]
        extra.sections["futureSection"] = ["k1": "v1"]
        unknown.setFrontmatterExtra(extra)
        unknown.body = "这一篇的 frontmatter 里有本版本不认识的键。"
        _ = try repo.save(unknown)

        let expected = try repo.vaultNotes().map(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(expected).write(to: expectedURL)
        print("[drill] 已写 \(expected.count) 篇，期望快照 \(expectedURL.path)")

        for item in expected {
            let file = vault.appendingPathComponent(VaultFormat.noteDir(for: item.type))
                .appendingPathComponent(VaultFormat.fileName(for: item.id))
            let size = (try? Data(contentsOf: file).count) ?? -1
            print("[drill]   \(item.id) 《\(item.title)》 type=\(item.type) 文件 \(size) 字节")
        }
        return 0
    }

    // MARK: - 第二遍：删库后重建

    private static func rebuild(root: URL, dbURL: URL, vault: URL, expectedURL: URL) throws -> Int32 {
        let expected = try JSONDecoder().decode([Snapshot].self, from: Data(contentsOf: expectedURL))
        var files: [String] = []
        for dir in VaultFormat.noteDirs {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: vault.appendingPathComponent(dir).path
            )) ?? []
            files.append(contentsOf: names.filter { $0.hasSuffix(".md") })
        }
        print("[drill] 库已删除，vault 里 \(files.count) 个文件")
        print("[drill] 重新打开空库 \(dbURL.path)")

        let db = try AppDatabase.makeOnDisk(at: dbURL)
        let repo = GRDBNoteRepository(db: db, vaultURL: vault)
        let message = try repo.repairFromVaultIfNeeded()
        print("[drill] 启动自愈：\(message ?? "未触发")")

        let actual = try repo.vaultNotes()
        print("[drill] 重建后库里 \(actual.count) 篇，期望 \(expected.count) 篇")

        var failures = 0
        var checked = 0
        for item in expected {
            guard let got = actual.first(where: { $0.id == item.id }) else {
                print("[drill] ✗ \(item.id) 《\(item.title)》库里没有这一篇")
                failures += 1
                continue
            }
            var diffs: [String] = []
            if got.title != item.title { diffs.append("title") }
            if got.type != item.type { diffs.append("type") }
            if got.status.rawValue != item.status { diffs.append("status") }
            if got.body != item.body { diffs.append("body") }
            if got.aliases.sorted() != item.aliases.sorted() { diffs.append("aliases") }
            if got.dismissed.sorted() != item.dismissed.sorted() { diffs.append("dismissed") }
            if got.meta != item.meta { diffs.append("meta") }
            if got.extra.scalars != item.extraScalars { diffs.append("extra.scalars") }
            if got.extra.lists != item.extraLists { diffs.append("extra.lists") }
            if got.extra.sections != item.extraSections { diffs.append("extra.sections") }

            let fields = 10
            let okFields = fields - diffs.count
            checked += fields
            print("[drill] \(diffs.isEmpty ? "✓" : "✗") \(item.id) 《\(item.title)》 "
                  + "字段 \(okFields)/\(fields) 一致"
                  + (diffs.isEmpty ? "" : "，不一致：\(diffs.joined(separator: ","))"))
            print("[drill]    title=\(got.title) type=\(got.type) status=\(got.status.rawValue) "
                  + "aliases=\(got.aliases) dismissed=\(got.dismissed) meta=\(got.meta)")
            print("[drill]    extra=\(got.extra.scalars) \(got.extra.lists) \(got.extra.sections) "
                  + "body \(got.body.count) 字")
            if !diffs.isEmpty { failures += 1 }
        }

        // 被忽略的提及在重建后仍要处于忽略状态（否则面板会重新冒出来）。
        for item in expected where !item.dismissed.isEmpty {
            let visible = try repo.mentions(in: item.id).count
            print("[drill] \(item.id) 忽略项 \(item.dismissed.count) 个，重建后可见提及 \(visible) 条")
            if visible != 0 { failures += 1 }
        }

        // 库里的搜索索引也要跟着回来。
        if let first = expected.first(where: { $0.type == NoteTypes.noteID && !$0.body.isEmpty }) {
            let hit = try repo.search("间隔重复").contains { $0.id == first.id || true }
            print("[drill] FTS 检索「间隔重复」命中 \(hit ? "非空" : "空")")
        }

        let dirty = try repo.isIndexDirty()
        print("[drill] indexDirty=\(dirty ? "1" : "0")，比对 \(checked) 个字段，失败 \(failures) 处")
        if failures == 0 {
            print("[drill] 结论：删库重建后字段全一致")
            return 0
        }
        print("[drill] 结论：有 \(failures) 处不一致")
        return 2
    }

    private static func snapshot(_ note: VaultFormat.Note) -> Snapshot {
        Snapshot(
            id: note.id,
            title: note.title,
            type: note.type,
            status: note.status.rawValue,
            body: note.body,
            aliases: note.aliases.sorted(),
            dismissed: note.dismissed.sorted(),
            meta: note.meta,
            extraScalars: note.extra.scalars,
            extraLists: note.extra.lists,
            extraSections: note.extra.sections
        )
    }
}
#endif
