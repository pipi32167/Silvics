import CryptoKit
import Foundation

/// vault 目录的格式定义。备份与同步共用这一份。
///
/// ```text
/// <vault>/
///   notes/<id>.md        真相层：frontmatter + 正文
///   manifest.json        内容索引：条数与每篇哈希
///   .base/<id>.md        上次同步时的版本，三方合并的 base（不进 git）
///   .conflicts/          合并不了的两份原文（不进 git）
///   .trash/              删除的笔记（不进 git）
/// ```
enum VaultFormat {

    static let schema = 1
    static let notesDir = "notes"
    static let baseDir = ".base"
    static let conflictsDir = ".conflicts"
    static let trashDir = ".trash"
    static let manifestName = "manifest.json"

    /// 会放进 vault 根目录的 `.gitignore`。索引与本地留档都不能进仓。
    static let gitignore = """
    .base/
    .conflicts/
    .trash/
    *.tmp-*
    .DS_Store

    """

    // MARK: - 一篇笔记

    struct Note: Equatable {
        var id: String
        var title: String
        var status: NoteStatus
        var createdAt: Int64      // 毫秒
        var updatedAt: Int64
        var aliases: [String]
        /// 已忽略的提及，存目标笔记 id（不是标题）。标题会改，id 不会。
        var dismissed: [String]
        var body: String
        /// 笔记类型。省略时按 `note` 处理。
        var type: String = NoteTypes.noteID
        /// 类型段字段，例如日记的 `date` / `carryFrom`。
        var meta: [String: String] = [:]
        /// 不认识的键。必须原样保留，否则新老版本互相踩数据。
        var extra: FrontmatterExtra = FrontmatterExtra()
    }

    /// frontmatter 里当前版本不认识的键。读进来存着，写回去一字不改。
    struct FrontmatterExtra: Equatable, Codable {
        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var sections: [String: [String: String]] = [:]

        var isEmpty: Bool { scalars.isEmpty && lists.isEmpty && sections.isEmpty }
    }

    enum ParseError: Error, LocalizedError {
        case missingHeader
        case missingField(String)
        case badDate(String)

        var errorDescription: String? {
            switch self {
            case .missingHeader: return "frontmatter 不完整"
            case .missingField(let f): return "frontmatter 缺字段 \(f)"
            case .badDate(let raw): return "时间格式不对：\(raw)"
            }
        }
    }

    static func fileName(for id: String) -> String { "\(id).md" }

    static func id(fromFileName name: String) -> String? {
        guard name.hasSuffix(".md") else { return nil }
        return String(name.dropLast(3))
    }

    // MARK: - 写

    /// 编码成文件内容。同样输入必得同样字节，否则 git 里天天全量 diff。
    ///
    /// 输出顺序固定：身份层 → 通用层 → 类型层 → 未知层。层内按 key 排序。
    static func encode(_ note: Note) -> String {
        var lines: [String] = ["---"]
        // 身份层
        lines.append("schema: \(schema)")
        lines.append("id: \(scalar(note.id))")
        if note.type != NoteTypes.noteID {
            lines.append("type: \(scalar(note.type))")
        }
        // 通用层
        lines.append("title: \(scalar(note.title))")
        lines.append("status: \(note.status.rawValue)")
        lines.append("created: \(dateString(note.createdAt))")
        lines.append("updated: \(dateString(note.updatedAt))")
        appendList(&lines, key: "aliases", values: note.aliases.sorted())
        appendList(&lines, key: "dismissed", values: note.dismissed.sorted())

        // 类型层
        let descriptor = NoteTypes.descriptor(for: note.type)
        if let namespace = descriptor.metaNamespace, !note.meta.isEmpty {
            lines.append("\(namespace):")
            for key in note.meta.keys.sorted() {
                lines.append("  \(key): \(scalar(note.meta[key] ?? ""))")
            }
        }

        // 未知层：原样保留
        for key in note.extra.scalars.keys.sorted() {
            lines.append("\(key): \(scalar(note.extra.scalars[key] ?? ""))")
        }
        for key in note.extra.lists.keys.sorted() {
            appendList(&lines, key: key, values: note.extra.lists[key] ?? [])
        }
        for key in note.extra.sections.keys.sorted() {
            lines.append("\(key):")
            for inner in (note.extra.sections[key] ?? [:]).keys.sorted() {
                lines.append("  \(inner): \(scalar(note.extra.sections[key]?[inner] ?? ""))")
            }
        }

        lines.append("---")
        lines.append(note.body)
        return lines.joined(separator: "\n")
    }

    private static func appendList(_ lines: inout [String], key: String, values: [String]) {
        guard !values.isEmpty else { return }
        lines.append("\(key):")
        for value in values {
            lines.append("  - \(scalar(value))")
        }
    }

    /// 只有必要时才加引号。标题禁止出现 `[ ] ( )`，别名同理。
    private static func scalar(_ raw: String) -> String {
        let needsQuote = raw.isEmpty
            || raw.hasPrefix(" ")
            || raw.hasSuffix(" ")
            || raw.hasPrefix("-")
            || raw.contains(": ")
            || raw.hasSuffix(":")
            || raw.contains(" #")
            || raw.hasPrefix("#")
            || raw.contains("\"")
            || raw.contains("\\")
            || raw.contains("\n")
        guard needsQuote else { return raw }
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func dateString(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    // MARK: - 读

    static func decode(_ text: String) throws -> Note {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { throw ParseError.missingHeader }
        guard let end = lines.dropFirst().firstIndex(of: "---") else { throw ParseError.missingHeader }

        var scalars: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var sections: [String: [String: String]] = [:]

        var i = 1
        while i < end {
            let line = lines[i]
            defer { i += 1 }
            guard !line.hasPrefix(" "), !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                scalars[key] = unscalar(value)
                continue
            }
            // 空值：后面缩进的行是列表项或子键
            var items: [String] = []
            var pairs: [String: String] = [:]
            var j = i + 1
            while j < end, lines[j].hasPrefix("  ") {
                let child = String(lines[j].dropFirst(2))
                if child.hasPrefix("- ") {
                    items.append(unscalar(String(child.dropFirst(2))))
                } else if let innerColon = child.firstIndex(of: ":") {
                    let innerKey = String(child[child.startIndex..<innerColon])
                    let innerValue = String(child[child.index(after: innerColon)...])
                        .trimmingCharacters(in: .whitespaces)
                    pairs[innerKey] = unscalar(innerValue)
                }
                j += 1
            }
            if !items.isEmpty || pairs.isEmpty {
                lists[key] = items
            } else {
                sections[key] = pairs
            }
            i = j - 1
        }

        guard let id = scalars["id"] else { throw ParseError.missingField("id") }
        guard let title = scalars["title"] else { throw ParseError.missingField("title") }
        let type = scalars["type"] ?? NoteTypes.noteID
        let status = NoteStatus(rawValue: scalars["status"] ?? "") ?? .seedling
        guard let created = parseDate(scalars["created"]) else { throw ParseError.badDate(scalars["created"] ?? "") }
        guard let updated = parseDate(scalars["updated"]) else { throw ParseError.badDate(scalars["updated"] ?? "") }

        // 已知键摘出来，剩下的按未知保留
        var meta: [String: String] = [:]
        if let namespace = NoteTypes.descriptor(for: type).metaNamespace, let section = sections.removeValue(forKey: namespace) {
            meta = section
        }
        var extra = FrontmatterExtra()
        for key in scalars.keys where !knownScalarKeys.contains(key) {
            extra.scalars[key] = scalars[key]
        }
        for key in lists.keys where !knownListKeys.contains(key) {
            extra.lists[key] = lists[key]
        }
        for key in sections.keys where !knownSectionKeys.contains(key) {
            extra.sections[key] = sections[key]
        }

        let body = lines[(end + 1)...].joined(separator: "\n")
        return Note(
            id: id,
            title: title,
            status: status,
            createdAt: created,
            updatedAt: updated,
            aliases: lists["aliases"] ?? [],
            dismissed: lists["dismissed"] ?? [],
            body: body,
            type: type,
            meta: meta,
            extra: extra
        )
    }

    /// 本版本认识的键。不在表里的键一律按未知原样保留。
    private static let knownScalarKeys: Set<String> = ["schema", "id", "type", "title", "status", "created", "updated"]
    private static let knownListKeys: Set<String> = ["aliases", "dismissed"]
    /// 所有已注册类型的命名空间都算已知，避免把类型段当成未知段再写一遍
    private static var knownSectionKeys: Set<String> {
        Set(NoteTypes.all.values.compactMap(\.metaNamespace))
    }

    private static func unscalar(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        let inner = String(raw.dropFirst().dropLast())
        var out = ""
        var escaped = false
        for ch in inner {
            if escaped {
                out.append(ch == "n" ? "\n" : ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func parseDate(_ raw: String?) -> Int64? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = isoFormatter.date(from: raw) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let plain = ISO8601DateFormatter()
        guard let date = plain.date(from: raw) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - 哈希

    /// 稳定哈希。Swift 的 `Hasher` 每个进程随机种子，不能用来做跨设备比对。
    static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - manifest

    struct Manifest: Codable, Equatable {
        var schema: Int
        var count: Int
        var notes: [Entry]

        struct Entry: Codable, Equatable {
            var id: String
            var hash: String
            var title: String
            var updated: Int64
        }
    }

    static func makeManifest(_ notes: [Note]) -> Manifest {
        Manifest(
            schema: schema,
            count: notes.count,
            notes: notes
                .map { Manifest.Entry(id: $0.id, hash: hash($0.body), title: $0.title, updated: $0.updatedAt) }
                .sorted { $0.id < $1.id }
        )
    }

    static func encodeManifest(_ manifest: Manifest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // 稳定输出：JSONEncoder 不保证换行与尾随换行，这里固定一个。
        var data = (try? encoder.encode(manifest)) ?? Data()
        if data.last != 0x0A { data.append(0x0A) }
        return data
    }

    static func decodeManifest(_ data: Data) -> Manifest? {
        try? JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - 落盘

    /// 原子写 + 幂等：内容没变就一个字节都不碰，避免 mtime 抖动让 git 误报改动。
    @discardableResult
    static func writeAtomic(_ data: Data, to url: URL) throws -> Bool {
        if let existing = try? Data(contentsOf: url), existing == data { return false }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        return true
    }
}
