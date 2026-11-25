import Foundation

/// vault 的导出、恢复、校验，以及基于 git 的双向同步。
///
/// 分工：git 只负责搬字节；合并由这里自己算。
/// 绝不让 git 做 merge —— 它会把 `<<<<<<<` 写进正文。
final class VaultSync {

    let repo: NoteRepository
    var settings: SyncSettings
    /// 最近一次同步里无法自动合并的正文冲突。由 `sync()` 重置。
    private(set) var lastConflicts: [VaultConflict] = []

    init(repo: NoteRepository, settings: SyncSettings) {
        self.repo = repo
        self.settings = settings
    }

    // MARK: - 路径

    var vaultURL: URL { settings.vaultURL }
    var notesURL: URL { vaultURL.appendingPathComponent(VaultFormat.notesDir, isDirectory: true) }
    var baseURL: URL { vaultURL.appendingPathComponent(VaultFormat.baseDir, isDirectory: true) }
    var conflictsURL: URL { vaultURL.appendingPathComponent(VaultFormat.conflictsDir, isDirectory: true) }
    var trashURL: URL { vaultURL.appendingPathComponent(VaultFormat.trashDir, isDirectory: true) }

    /// 某个类型目录的完整 URL。
    func noteDirURL(_ dir: String) -> URL {
        vaultURL.appendingPathComponent(dir, isDirectory: true)
    }

    /// 所有已知笔记目录。`notes/` 一定在第一个。
    var noteDirURLs: [URL] { VaultFormat.noteDirs.map(noteDirURL) }

    var git: GitClient {
        GitClient(
            workDir: vaultURL,
            sshKeyPath: settings.effectiveSSHKeyPath,
            authorName: settings.authorName,
            authorEmail: settings.authorEmail
        )
    }

    func prepareDirectories() throws {
        let fm = FileManager.default
        for dir in [vaultURL, baseURL, conflictsURL, trashURL] + noteDirURLs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let ignore = vaultURL.appendingPathComponent(".gitignore")
        try VaultFormat.writeAtomic(Data(VaultFormat.gitignore.utf8), to: ignore)
    }

    /// 某类型是否纳入同步。剪藏可以单独关掉，避免把长正文推上 git。
    private func shouldSync(type: String) -> Bool {
        settings.syncClips || type != NoteTypes.clipID
    }

    // MARK: - 导出

    /// 把库写成 vault。返回真正改动的文件数（幂等：内容没变一个字节都不碰）。
    ///
    /// **导出只写不删。** 库空了（换机器、库文件丢了）不能连带把 vault 清空 ——
    /// 那样一次误操作就把备份也干掉。删除只走 `removeFromVault`，由用户动作触发。
    @discardableResult
    func exportAll() throws -> Int {
        try prepareDirectories()
        let snapshot = try repo.vaultNotes().filter { shouldSync(type: $0.type) }
        var written = 0
        var live = Set<String>()

        for note in snapshot {
            live.insert(note.id)
            let data = Data(VaultFormat.encode(note).utf8)
            let url = noteDirURL(VaultFormat.noteDir(for: note.type))
                .appendingPathComponent(VaultFormat.noteFileName(id: note.id, type: note.type))
            if try VaultFormat.writeAtomic(data, to: url) { written += 1 }
        }

        _ = live
        let manifest = VaultFormat.makeManifest(snapshot)
        if try VaultFormat.writeAtomic(
            VaultFormat.encodeManifest(manifest),
            to: vaultURL.appendingPathComponent(VaultFormat.manifestName)
        ) {
            written += 1
        }
        return written
    }

    /// 笔记被删掉时同步删掉 vault 里的文件。只有用户主动删除才调用。
    func removeFromVault(id: String) throws {
        let fm = FileManager.default
        // 类型可能已经被改过，逐个目录找，不让旧目录里的文件变成孤儿。
        // 日记的文件名是日期，不是 id，所以两种名字都要试。
        var names = [VaultFormat.fileName(for: id)]
        if let date = VaultFormat.journalDate(fromID: id) {
            names.append(VaultFormat.fileName(for: date))
        }
        for dir in noteDirURLs {
            for name in names {
                let file = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            }
        }
        let base = baseFileURL(id)
        if fm.fileExists(atPath: base.path) { try fm.removeItem(at: base) }
    }

    // MARK: - 读取 vault

    func readVaultNotes() throws -> [VaultFormat.Note] {
        var entries: [(dir: String, note: VaultFormat.Note)] = []
        for dir in VaultFormat.noteDirs {
            let base = noteDirURL(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".md") {
                let url = base.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                guard let note = try? VaultFormat.decode(text) else { continue }
                entries.append((dir, note))
            }
        }
        return VaultFormat.dedupe(entries)
    }

    /// 从 vault 全量恢复（新机器、或库被清空）。返回报告。
    @discardableResult
    func importAll() throws -> VaultImportReport {
        // 关闭「同步剪藏」时，从 vault 恢复也不能把剪藏拉回库。
        let notes = try readVaultNotes().filter { shouldSync(type: $0.type) }
        return try repo.importVaultNotes(notes)
    }

    // MARK: - 校验

    struct VerifyResult {
        var ok: Bool
        var problems: [String]
        var summary: String
    }

    func verify() throws -> VerifyResult {
        var problems: [String] = []
        let fm = FileManager.default

        if !fm.fileExists(atPath: vaultURL.path) {
            return VerifyResult(ok: false, problems: ["vault 目录不存在"], summary: "未初始化")
        }

        let manifestURL = vaultURL.appendingPathComponent(VaultFormat.manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = VaultFormat.decodeManifest(data)
        else {
            return VerifyResult(ok: false, problems: ["manifest.json 缺失或损坏"], summary: "未初始化")
        }

        var fileIds = Set<String>()
        for dir in noteDirURLs {
            let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in files where name.hasSuffix(".md") {
                guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8),
                      let note = try? VaultFormat.decode(text)
                else { continue }
                guard shouldSync(type: note.type) else { continue }
                fileIds.insert(note.id)
            }
        }
        let enabledDirs = Set(VaultFormat.noteDirs.filter { settings.syncClips || $0 != VaultFormat.noteDir(for: NoteTypes.clipID) })
        let manifestIds = Set(manifest.notes
            .filter { enabledDirs.contains($0.dir ?? VaultFormat.notesDir) }
            .map(\.id))

        if fileIds != manifestIds {
            let missing = manifestIds.subtracting(fileIds)
            let extra = fileIds.subtracting(manifestIds)
            if !missing.isEmpty { problems.append("manifest 里有 \(missing.count) 篇文件不存在") }
            if !extra.isEmpty { problems.append("有 \(extra.count) 篇文件不在 manifest 里") }
        }
        if manifest.count != manifest.notes.count {
            problems.append("manifest.count 与条目数不符")
        }

        if manifest.schema < VaultFormat.manifestSchema {
            problems.append("manifest 是旧版本（schema \(manifest.schema)），下次同步会按整篇重写")
        } else {
            var hashMismatch = 0
            for entry in manifest.notes where enabledDirs.contains(entry.dir ?? VaultFormat.notesDir) {
                let dir = entry.dir ?? VaultFormat.notesDir
                let file = entry.file ?? VaultFormat.fileName(for: entry.id)
                let url = noteDirURL(dir).appendingPathComponent(file)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    hashMismatch += 1
                    continue
                }
                guard let note = try? VaultFormat.decode(text) else {
                    problems.append("\(entry.id) 解析失败")
                    continue
                }
                if VaultFormat.contentHash(note) != entry.hash { hashMismatch += 1 }
            }
            if hashMismatch > 0 { problems.append("\(hashMismatch) 篇整篇哈希与 manifest 不一致") }
        }

        let local = try repo.vaultNotes().filter { shouldSync(type: $0.type) }
        if local.count != manifest.count {
            problems.append("库里 \(local.count) 篇，vault 里 \(manifest.count) 篇")
        }

        let git = self.git
        if git.isRepository() {
            let branch = (try? git.currentBranch()) ?? settings.branch
            if git.remoteURL() == nil { problems.append("没有配置远端") }
            let ab = git.aheadBehind(branch: branch)
            if ab.ahead > 0 || ab.behind > 0 {
                problems.append("与远端不同步：领先 \(ab.ahead)，落后 \(ab.behind)")
            }
        }

        let ok = problems.isEmpty
        let summary = ok
            ? "\(manifest.count) 篇，哈希一致"
            : "\(problems.count) 个问题"
        return VerifyResult(ok: ok, problems: problems, summary: summary)
    }

    // MARK: - 同步

    struct Report {
        var exportedFiles = 0
        var importedNotes = 0
        var removedNotes = 0
        var pushed = false
        var conflicts: [String] = []
        var notes: [String] = []

        var summary: String {
            var parts: [String] = []
            if importedNotes > 0 { parts.append("拉入 \(importedNotes) 篇") }
            if removedNotes > 0 { parts.append("远端删除 \(removedNotes) 篇") }
            if exportedFiles > 0 { parts.append("写出 \(exportedFiles) 个文件") }
            if pushed { parts.append("已推送") }
            if !conflicts.isEmpty { parts.append("\(conflicts.count) 处冲突待处理") }
            return parts.isEmpty ? "无变化" : parts.joined(separator: "，")
        }
    }

    /// 双向同步。失败抛错，调用方负责提示。
    func sync() throws -> Report {
        lastConflicts = []
        var report = Report()

        // 先补齐「vault 里有、库里没有」的笔记。
        // 换机器、库文件丢了、库被清空，都靠这一步自动恢复 —— 用户不需要先点「从 vault 恢复」。
        report.importedNotes += try reconcileWithDisk()

        report.exportedFiles = try exportAll()

        let git = self.git
        if !git.isRepository() {
            guard settings.isConfigured else {
                throw SyncError.notConfigured
            }
            try git.initialize(remote: settings.remoteURL, branch: settings.branch)
        } else if settings.isConfigured, git.remoteURL() != settings.remoteURL {
            try git.setRemote(settings.remoteURL)
        }

        // 关闭「同步剪藏」时，clips/ 既不进暂存，也不参与「有没有改动」的判断。
        let excludes: [String] = settings.syncClips ? [] : [VaultFormat.noteDir(for: NoteTypes.clipID)]
        if !excludes.isEmpty { git.unstage(excludes) }
        if git.hasLocalChanges(excluding: excludes) {
            try git.stageAll(excluding: excludes)
            if git.stagedChangesExist() {
                try git.commit(commitMessage())
            }
        }

        try git.fetch()
        let branch = (try? git.currentBranch()) ?? settings.branch

        if !git.remoteBranchExists(branch) {
            try git.push(branch: branch, setUpstream: true)
            report.pushed = true
            try writeBaseFiles()
            return report
        }

        var attempt = 0
        while true {
            attempt += 1
            let ab = git.aheadBehind(branch: branch)
            if ab.behind > 0 {
                let resolution = try resolveRemote(branch: branch)
                report.importedNotes += resolution.imported
                report.removedNotes += resolution.removed
                report.conflicts += resolution.conflicts
                report.notes += resolution.notes

                // 顺序很重要：先把合并结果提交成普通提交，工作区干净了才能让 git 记录合并。
                // 反过来的话，`git merge` 会因为暂存区有改动而失败，历史里就没有远端那个父提交。
                report.exportedFiles += try exportAll()
                try git.stageAll()
                let message = "merge: 同步 \(deviceShortId()) \(timestamp())"
                if git.stagedChangesExist() {
                    try git.commit(message)
                }
                if git.mergeBase("origin/\(branch)") != nil {
                    git.beginMergeKeepingOurs("origin/\(branch)")
                    try git.commit(message, allowEmpty: true)
                } else if git.isTreeEqual(to: "origin/\(branch)") {
                    // 没有共同祖先，且内容已经一致：直接采纳远端历史，别制造分叉。
                    git.resetHard("origin/\(branch)")
                } else {
                    git.beginMergeKeepingOurs("origin/\(branch)", allowUnrelated: true)
                    try git.commit(message, allowEmpty: true)
                }
            }

            do {
                if git.aheadBehind(branch: branch).ahead > 0 || !git.remoteBranchExists(branch) {
                    try git.push(branch: branch)
                    report.pushed = true
                }
                break
            } catch {
                // 多设备并发推送会被拒。重拉一次再解一次，第二次还失败就报错。
                if attempt >= 2 { throw error }
                try git.fetch()
            }
        }

        try writeBaseFiles()
        return report
    }

    enum SyncError: LocalizedError {
        case notConfigured
        case badRemote(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "还没配置远端仓库地址"
            case .badRemote(let url): return "远端地址不像是 git 仓库：\(url)"
            }
        }
    }

    /// 磁盘上有、库里没有的笔记，直接收进库。返回收进来的篇数。
    ///
    /// 删除笔记会同时删掉 vault 文件（`removeFromVault`），所以「文件在而库里没有」
    /// 只可能是库丢了。
    @discardableResult
    func reconcileWithDisk() throws -> Int {
        let disk = try readVaultNotes()
        guard !disk.isEmpty else { return 0 }
        let known = Set(try repo.vaultNotes().map(\.id))
        let missing = disk.filter { !known.contains($0.id) && shouldSync(type: $0.type) }
        guard !missing.isEmpty else { return 0 }
        let report = try repo.importVaultNotes(missing)
        return report.inserted + report.updated
    }

    // MARK: - 冲突解决

    private struct Resolution {
        var imported = 0
        var removed = 0
        var conflicts: [String] = []
        var notes: [String] = []
    }

    private func resolveRemote(branch: String) throws -> Resolution {
        var result = Resolution()
        let git = self.git
        let baseRev = git.mergeBase("origin/\(branch)") ?? "HEAD"
        let changed = git.changedPaths(from: baseRev, to: "origin/\(branch)")

        var localById: [String: VaultFormat.Note] = [:]
        for note in try repo.vaultNotes() { localById[note.id] = note }

        var toImport: [VaultFormat.Note] = []
        var toDelete: [String] = []

        for path in changed {
            guard VaultFormat.isNotePath(path) else { continue }
            // 关闭「同步剪藏」时，clips/ 的变化一律不处理。文件留在 vault 里，不删。
            if !settings.syncClips, path.hasPrefix(VaultFormat.noteDir(for: NoteTypes.clipID) + "/") {
                continue
            }
            guard let id = VaultFormat.noteID(fromFileName: (path as NSString).lastPathComponent) else { continue }

            let remoteText = git.fileContent(path: path, ref: "origin/\(branch)")
            let remote = remoteText.flatMap { try? VaultFormat.decode($0) }
            let base = readBase(id).flatMap { try? VaultFormat.decode($0) }
            let local = localById[id]

            switch (remote, local) {
            case (nil, nil):
                continue

            case (nil, let local?):
                // 远端删了。本地没改就跟着删，改过就保留。
                if base == nil || (base!.body == local.body) {
                    toDelete.append(id)
                    archiveToTrash(local, reason: "remote-deleted")
                    result.removed += 1
                } else {
                    result.conflicts.append("《\(local.title)》远端已删除，本地有改动，已保留")
                }

            case (let remote?, nil):
                // 本地没有，远端有。要么是新笔记，要么是本机删了而远端改过。
                // 没 base 说明没同步过 → 直接收；有 base 且远端没变 → 尊重本机删除；否则复活。
                if base == nil || base!.body != remote.body {
                    toImport.append(remote)
                    result.imported += 1
                    result.notes.append("拉入《\(remote.title)》")
                }

            case (let remote?, let local?):
                if remote.body == local.body {
                    // 正文相同，元数据按全字段三方合并。真变了才写，否则每次同步都白跑一遍。
                    let merge = mergeMetadata(base: base, local: local, remote: remote)
                    if !merge.conflicts.isEmpty {
                        result.conflicts += merge.conflicts
                        archiveConflict(local, remote: remote, id: id)
                    }
                    if merge.note != local {
                        toImport.append(merge.note)
                        result.imported += 1
                    }
                    continue
                }
                if base?.body == local.body {
                    // 本地没改正文：正文取远端，元数据仍要三方合并（本地可能改过 frontmatter）。
                    let merge = mergeMetadata(base: base, local: local, remote: remote)
                    var pulled = merge.note
                    pulled.body = remote.body
                    if !merge.conflicts.isEmpty {
                        result.conflicts += merge.conflicts
                        archiveConflict(local, remote: remote, id: id)
                    }
                    toImport.append(pulled)
                    result.imported += 1
                    result.notes.append("拉入《\(pulled.title)》")
                    continue
                }
                if base?.body == remote.body {
                    continue  // 远端没改正文，保留本地
                }
                // 两边都改了正文
                if local.title != remote.title {
                    result.conflicts.append("《\(local.title)》两边都改了标题，未合并")
                    lastConflicts.append(VaultConflict(
                        noteId: id,
                        title: local.title,
                        base: base?.body ?? "",
                        ours: local.body,
                        theirs: remote.body
                    ))
                    archiveConflict(local, remote: remote, id: id)
                    continue
                }
                guard let base, let outcome = LineMerge.merge(
                    base: base.body, ours: local.body, theirs: remote.body
                ), outcome.isClean else {
                    result.conflicts.append("《\(local.title)》正文两边都改了，未合并，已留档")
                    lastConflicts.append(VaultConflict(
                        noteId: id,
                        title: local.title,
                        base: base?.body ?? "",
                        ours: local.body,
                        theirs: remote.body
                    ))
                    archiveConflict(local, remote: remote, id: id)
                    continue
                }
                var merge = mergeMetadata(base: base, local: local, remote: remote)
                var merged = merge.note
                merged.body = outcome.text
                merged.updatedAt = max(local.updatedAt, remote.updatedAt)
                if !merge.conflicts.isEmpty {
                    result.conflicts += merge.conflicts
                    archiveConflict(local, remote: remote, id: id)
                }
                toImport.append(merged)
                result.imported += 1
                result.notes.append("合并《\(merged.title)》")
            }
        }

        if !toImport.isEmpty {
            // 标题被别的 id 占住时不能覆盖。这类冲突也要报出来，否则看起来「同步成功」实际丢了一篇。
            let importReport = try repo.importVaultNotes(toImport)
            result.conflicts += importReport.titleConflicts
        }
        for id in toDelete {
            try? repo.delete(id: id)
        }
        return result
    }

    /// 元数据三方合并的结果。`conflicts` 非空时调用方要留档（`.conflicts/`）。
    private struct MetadataMerge {
        var note: VaultFormat.Note
        var conflicts: [String]
    }

    /// 元数据合并。规则：
    ///
    /// - `type`：两边不同 → 记冲突、留档，不自动选，保留本机
    /// - `title`：本地没改（== base）而远端改了 → 取远端；两边都改 → 记冲突、留档、保留本机
    /// - `status`：同 title 的三方判定
    /// - `meta`：按键并集；同键值不同时未改的一侧让位，两边都改 → 记冲突、留档、保留本机
    /// - `extra`：scalars / lists / sections / rawSections 全取并集（同键冲突保留本机，标量冲突记档）
    /// - 时间取极值，别名与已忽略提及取并集
    private func mergeMetadata(
        base: VaultFormat.Note?,
        local: VaultFormat.Note,
        remote: VaultFormat.Note
    ) -> MetadataMerge {
        var merged = local
        var conflicts: [String] = []

        merged.createdAt = min(local.createdAt, remote.createdAt)
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        // 集合字段用三方合并：本地删掉的别名、标签、忽略项不会被远端复活。
        merged.aliases = Self.mergeSet(base: base?.aliases ?? [], local: local.aliases, remote: remote.aliases)
        merged.dismissed = Self.mergeSet(
            base: base?.dismissed ?? [], local: local.dismissed, remote: remote.dismissed
        )
        merged.tags = Self.mergeSet(base: base?.tags ?? [], local: local.tags, remote: remote.tags)

        if local.type != remote.type {
            conflicts.append(
                "《\(local.title)》type 两边不同（本机 \(local.type) / 远端 \(remote.type)），未自动选择，已留档"
            )
        }

        if local.title != remote.title {
            if base?.title == local.title {
                merged.title = remote.title          // 只有远端改了标题
            } else if base?.title != remote.title {
                conflicts.append(
                    "《\(local.title)》标题两边都改了（本机 \(local.title) / 远端 \(remote.title)），已留档"
                )
            }
        }

        if local.status != remote.status {
            if base?.status == local.status {
                merged.status = remote.status
            } else if base?.status != remote.status {
                conflicts.append(
                    "《\(local.title)》状态两边都改了（本机 \(local.status.rawValue) / 远端 \(remote.status.rawValue)），已留档"
                )
            }
        }

        let meta = mergeStringMap(base: base?.meta ?? [:], local: local.meta, remote: remote.meta)
        merged.meta = meta.map
        if !meta.conflicting.isEmpty {
            conflicts.append(
                "《\(local.title)》类型段 \(meta.conflicting.sorted().joined(separator: "、")) 两边值不同，保留本机值，已留档"
            )
        }

        let baseExtra = base?.extra ?? VaultFormat.FrontmatterExtra()
        var extra = local.extra

        let scalars = mergeStringMap(
            base: baseExtra.scalars, local: local.extra.scalars, remote: remote.extra.scalars
        )
        extra.scalars = scalars.map
        if !scalars.conflicting.isEmpty {
            conflicts.append(
                "《\(local.title)》未知键 \(scalars.conflicting.sorted().joined(separator: "、")) 两边值不同，保留本机值，已留档"
            )
        }

        for (key, values) in remote.extra.lists {
            guard var existing = extra.lists[key] else {
                extra.lists[key] = values
                continue
            }
            var seen = Set(existing)
            for value in values where seen.insert(value).inserted { existing.append(value) }
            extra.lists[key] = existing
        }

        for (key, remotePairs) in remote.extra.sections {
            let section = mergeStringMap(
                base: baseExtra.sections[key] ?? [:],
                local: local.extra.sections[key] ?? [:],
                remote: remotePairs
            )
            extra.sections[key] = section.map
            if !section.conflicting.isEmpty {
                conflicts.append(
                    "《\(local.title)》未知段 \(key) 的 \(section.conflicting.sorted().joined(separator: "、")) 两边值不同，保留本机值，已留档"
                )
            }
        }

        for (key, lines) in remote.extra.rawSections where extra.rawSections[key] == nil {
            extra.rawSections[key] = lines
        }
        merged.extra = extra

        return MetadataMerge(note: merged, conflicts: conflicts)
    }

    /// 集合字段的三方合并：`base + (local − base) + (remote − base)`。
    ///
    /// 本地删掉的项不会被远端复活；一边删一边加时保留新增。输出排序，保证字节稳定。
    static func mergeSet(base: [String], local: [String], remote: [String]) -> [String] {
        let baseSet = Set(base)
        var out = Set(local)
        for item in remote where !out.contains(item) {
            // 只有远端新增（base 里没有）才补回来。远端没改的项不复活本地的删除。
            if !baseSet.contains(item) { out.insert(item) }
        }
        return out.sorted()
    }

    /// 键并集 + 同键值不同的三方判定。未改的一侧让位，两边都改就记下来交给人。
    private func mergeStringMap(
        base: [String: String],
        local: [String: String],
        remote: [String: String]
    ) -> (map: [String: String], conflicting: [String]) {
        var out = local
        var conflicting: [String] = []
        for (key, remoteValue) in remote {
            guard let localValue = out[key] else {
                out[key] = remoteValue
                continue
            }
            if localValue == remoteValue { continue }
            if base[key] == localValue {
                out[key] = remoteValue              // 本地没改过这个键 → 取远端
            } else if base[key] != remoteValue {
                conflicting.append(key)             // 两边都改了 → 保留本机并留档
            }
        }
        return (out, conflicting)
    }

    // MARK: - base 与留档

    private func baseFileURL(_ id: String) -> URL {
        baseURL.appendingPathComponent(VaultFormat.fileName(for: id))
    }

    private func readBase(_ id: String) -> String? {
        try? String(contentsOf: baseFileURL(id), encoding: .utf8)
    }

    /// 同步成功后把当前文件全部记为 base。下次三方合并要用。
    private func writeBaseFiles() throws {
        try prepareDirectories()
        var live = Set<String>()
        for dir in noteDirURLs {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasSuffix(".md") {
                let url = dir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url) else { continue }
                // 日记的文件名是日期，id 只能从内容里读。
                guard let note = try? VaultFormat.decode(String(decoding: data, as: UTF8.self)) else { continue }
                live.insert(note.id)
                try VaultFormat.writeAtomic(data, to: baseFileURL(note.id))
            }
        }
        let bases = (try? FileManager.default.contentsOfDirectory(atPath: baseURL.path)) ?? []
        for name in bases where name.hasSuffix(".md") {
            guard let id = VaultFormat.id(fromFileName: name), !live.contains(id) else { continue }
            try? FileManager.default.removeItem(at: baseFileURL(id))
        }
    }

    private func archiveConflict(_ local: VaultFormat.Note, remote: VaultFormat.Note, id: String) {
        let stamp = timestamp()
        let remoteURL = conflictsURL.appendingPathComponent(
            "\(id).\(deviceShortId()).\(stamp).remote.md"
        )
        try? VaultFormat.writeAtomic(Data(VaultFormat.encode(remote).utf8), to: remoteURL)
        let localURL = conflictsURL.appendingPathComponent(
            "\(id).\(deviceShortId()).\(stamp).local.md"
        )
        try? VaultFormat.writeAtomic(Data(VaultFormat.encode(local).utf8), to: localURL)
    }

    private func archiveToTrash(_ note: VaultFormat.Note, reason: String) {
        let url = trashURL.appendingPathComponent("\(note.id).\(reason).md")
        try? VaultFormat.writeAtomic(Data(VaultFormat.encode(note).utf8), to: url)
    }

    // MARK: - 文案

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: Date())
    }

    private func deviceShortId() -> String {
        (try? repo.deviceId()) ?? "unknown"
    }

    private func commitMessage() -> String {
        "sync: \(deviceShortId()) \(timestamp())"
    }
}
