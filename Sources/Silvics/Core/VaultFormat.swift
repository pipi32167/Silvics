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
    static func encode(_ note: Note) -> String {
        var lines: [String] = ["---"]
        lines.append("schema: \(schema)")
        lines.append("id: \(scalar(note.id))")
        lines.append("title: \(scalar(note.title))")
        lines.append("status: \(note.status.rawValue)")
        lines.append("created: \(dateString(note.createdAt))")
        lines.append("updated: \(dateString(note.updatedAt))")
        appendList(&lines, key: "aliases", values: note.aliases.sorted())
        appendList(&lines, key: "dismissed", values: note.dismissed.sorted())
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

        var fields: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var listKey: String?

        for line in lines[1..<end] {
            if line.hasPrefix("  - ") {
                guard let key = listKey else { continue }
                lists[key, default: []].append(unscalar(String(line.dropFirst(4))))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                listKey = key
                lists[key] = []
            } else {
                listKey = nil
                fields[key] = unscalar(value)
            }
        }

        guard let id = fields["id"] else { throw ParseError.missingField("id") }
        guard let title = fields["title"] else { throw ParseError.missingField("title") }
        let status = NoteStatus(rawValue: fields["status"] ?? "") ?? .seedling
        guard let created = parseDate(fields["created"]) else { throw ParseError.badDate(fields["created"] ?? "") }
        guard let updated = parseDate(fields["updated"]) else { throw ParseError.badDate(fields["updated"] ?? "") }

        let body = lines[(end + 1)...].joined(separator: "\n")
        return Note(
            id: id,
            title: title,
            status: status,
            createdAt: created,
            updatedAt: updated,
            aliases: lists["aliases"] ?? [],
            dismissed: lists["dismissed"] ?? [],
            body: body
        )
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
