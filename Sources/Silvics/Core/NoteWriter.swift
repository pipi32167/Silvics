import Foundation

/// 保存链路：**先写 vault 文件，再更新 sqlite 索引**。
///
/// 顺序不能反。文件是真相，库只是索引；先写库再导出的话，导出失败就变成
/// 「库里有、文件没有」，删库重建直接丢内容。
///
/// 三步：
/// 1. 算出 vault 文件内容（`VaultFormat.encode`，稳定序列化）。
/// 2. 与磁盘上已有的字节比较：一样就一个字节都不碰。
/// 3. 原子写成功后，才写库并重算这一篇的索引。
///
/// 失败语义：
/// - 文件写失败 → 抛错，库不动，界面能拿到原因。
/// - 库写失败 → 文件已是真相，把 `meta.indexDirty` 置 1，下次启动全量重算；错误照样抛。
enum NoteWriter {

    struct Outcome: Equatable {
        var note: Note
        /// 是否真的写了文件。内容没变时为 false。
        var wroteFile: Bool
    }

    enum SaveError: LocalizedError {
        case titleTaken(String)
        case vaultWriteFailed(URL, String)
        case indexWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .titleTaken(let title):
                return "已有同名笔记《\(title)》，没有保存"
            case .vaultWriteFailed(let url, let reason):
                return "写 vault 文件失败（\(url.path)）：\(reason)"
            case .indexWriteFailed(let reason):
                return "vault 已写入，但索引更新失败，下次启动会全量重算：\(reason)"
            }
        }
    }

    // MARK: - 保存

    /// 保存一篇：文件先行，库随后。
    static func save(_ note: Note, repo: GRDBNoteRepository) throws -> Outcome {
        var updated = note
        updated.titleKey = TextNormalizer.key(updated.title)
        updated.bodyHash = TextNormalizer.bodyHash(updated.body)

        // 重名要先拦。先写文件再发现重名，会在 vault 里留一个孤儿文件。
        if try repo.titleTaken(updated.titleKey, excluding: updated.id) {
            throw SaveError.titleTaken(updated.title)
        }

        let metadata = try repo.vaultMetadata(for: updated.id)
        let url = repo.vaultFileURL(for: updated.id, type: updated.type)

        var wroteFile = false
        if try isUnchanged(updated, metadata: metadata, at: url) == false {
            // 内容真的变了才动时间戳：不动的话每次保存都全量改写文件，git 天天 diff。
            updated.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
            let data = Data(VaultFormat.encode(vaultNote(updated, metadata: metadata)).utf8)
            do {
                try VaultFormat.writeAtomic(data, to: url)
                // 类型改了会写到另一个目录，旧目录那份要处理掉，否则同一 id 两份文件。
                // 不能直接删：旧目录那份可能被用户手改过，正文与这份不同。
                updated = reconcileStaleCopies(of: updated, metadata: metadata, repo: repo)
            } catch {
                // 文件没写成：库保持原样，索引也别动。
                throw SaveError.vaultWriteFailed(url, error.localizedDescription)
            }
            wroteFile = true
        }

        do {
            try repo.writeNoteRow(updated)
        } catch {
            // 文件已经落盘，不能再骗人说没保存。标记索引过期，错误抛出去。
            try? repo.setIndexDirty(true)
            throw SaveError.indexWriteFailed(error.localizedDescription)
        }
        return Outcome(note: updated, wroteFile: wroteFile)
    }

    /// 同一个 id 只留一份**活文件**，但别的目录里那份不能直接删。
    ///
    /// 旧版本把日记写在 `notes/<id>.md`，新版本写 `journal/<日期>.md`；两份正文可能不同
    /// （用户手改过旧目录那份）。直接删 = 丢内容。规则：
    ///
    /// - 按 frontmatter 的 `updated:` 比较，**较新的那份留在类型目录**；
    /// - 另一份（旧目录的、或刚写的）复制进 `.trash/` 后从原目录移除，不直接删；
    /// - 较新的是旧目录那份时，返回带它正文与时间的笔记，调用方据此落库，
    ///   否则文件和库各说一套；
    /// - 读不出来或解析不了的文件原地不动，留给人看。
    ///
    /// 文件名由 id（或日记日期）推出来，不会与别的笔记撞名。
    private static func reconcileStaleCopies(
        of note: Note,
        metadata: (aliases: [String], dismissed: [String]),
        repo: GRDBNoteRepository
    ) -> Note {
        let fm = FileManager.default
        let target = repo.vaultFileURL(for: note.id, type: note.type)
        var current = note

        for stale in staleCopyURLs(of: note, repo: repo) where stale.path != target.path {
            guard let raw = try? Data(contentsOf: stale),
                  let other = try? VaultFormat.decode(String(decoding: raw, as: UTF8.self))
            else { continue }

            // 内容一样：删掉不丢东西，照样留一份档。
            if other.body == current.body {
                archive(raw, from: stale, reason: "same-content", repo: repo)
                try? fm.removeItem(at: stale)
                continue
            }

            // 旧目录那份更新：以它为准，把刚写的那份存进 .trash。
            if other.updatedAt > current.updatedAt {
                var adopted = current
                adopted.body = other.body
                adopted.bodyHash = TextNormalizer.bodyHash(other.body)
                adopted.updatedAt = other.updatedAt
                let winner = Data(VaultFormat.encode(vaultNote(adopted, metadata: metadata)).utf8)
                // 写不成就别动旧环境那份，宁可留两份也不能丢。
                guard (try? VaultFormat.writeAtomic(winner, to: target)) != nil else { continue }
                archive(
                    Data(VaultFormat.encode(vaultNote(current, metadata: metadata)).utf8),
                    from: stale,
                    reason: "superseded",
                    repo: repo
                )
                try? fm.removeItem(at: stale)
                current = adopted
                continue
            }

            // 常规情况：刚写的那份更新，旧目录那份留档后移出。
            archive(raw, from: stale, reason: "stale-copy", repo: repo)
            try? fm.removeItem(at: stale)
        }
        return current
    }

    /// 同一个 id 在别的目录里可能存在文件。日记的文件名是日期不是 id，两种名字都要试。
    /// 返回包含目标路径在内的所有命中文件，调用方自己排除目标。
    private static func staleCopyURLs(of note: Note, repo: GRDBNoteRepository) -> [URL] {
        var names = Set([VaultFormat.fileName(for: note.id)])
        if let date = VaultFormat.journalDate(fromID: note.id) {
            names.insert(VaultFormat.fileName(for: date))
        }
        let fm = FileManager.default
        var urls: [URL] = []
        for dir in repo.vaultNoteDirs {
            for name in names.sorted() {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { urls.append(url) }
            }
        }
        return urls
    }

    /// 把一份文件复制进 `.trash/`。重名但内容不同就加序号，绝不覆盖已有留档。
    private static func archive(_ data: Data, from source: URL, reason: String, repo: GRDBNoteRepository) {
        let dir = repo.vaultURL.appendingPathComponent(VaultFormat.trashDir, isDirectory: true)
        let dirName = source.deletingLastPathComponent().lastPathComponent
        let stem = "\(dirName)-\(source.deletingPathExtension().lastPathComponent).\(reason)"
        var candidate = dir.appendingPathComponent("\(stem).md")
        var index = 2
        while let existing = try? Data(contentsOf: candidate) {
            if existing == data { return }
            candidate = dir.appendingPathComponent("\(stem)-\(index).md")
            index += 1
        }
        try? VaultFormat.writeAtomic(data, to: candidate)
    }

    /// 内容与磁盘上的文件逐字节相同？相同就什么都不做。
    private static func isUnchanged(
        _ note: Note,
        metadata: (aliases: [String], dismissed: [String]),
        at url: URL
    ) throws -> Bool {
        guard let existing = try? Data(contentsOf: url) else { return false }
        let candidate = Data(VaultFormat.encode(vaultNote(note, metadata: metadata)).utf8)
        return existing == candidate
    }

    // MARK: - 其他写通路

    /// 把库里现有的某几篇（连同别名与已忽略提及）写回 vault。内容没变不写。
    ///
    /// 给「直接改库」的老通路补文件：改名、别名、批量转换、撤销、忽略提及。
    /// 这些通路库已经改完，这里只把文件补齐，保证文件仍是真相。
    @discardableResult
    static func flush(noteIds: [String], repo: GRDBNoteRepository) throws -> Int {
        var written = 0
        for id in Set(noteIds) {
            guard let note = try repo.note(id: id) else { continue }
            let metadata = try repo.vaultMetadata(for: id)
            let data = Data(VaultFormat.encode(vaultNote(note, metadata: metadata)).utf8)
            if try VaultFormat.writeAtomic(data, to: repo.vaultFileURL(for: id, type: note.type)) { written += 1 }
        }
        return written
    }

    // MARK: - 编码

    /// 库里的 `Note` → vault 里的笔记。别名与忽略项不在正文里，必须从库里补进来。
    static func vaultNote(
        _ note: Note,
        metadata: (aliases: [String], dismissed: [String])
    ) -> VaultFormat.Note {
        VaultFormat.Note(
            id: note.id,
            title: note.title,
            status: note.status,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            aliases: metadata.aliases,
            dismissed: metadata.dismissed,
            body: note.body,
            type: note.type,
            meta: note.metaFields,
            extra: note.frontmatterExtra
        )
    }
}
