import CryptoKit
import Foundation
import GRDB

// MARK: - 文本归一化

enum TextNormalizer {
    /// 标题匹配键：小写、去首尾空白、全角转半角、压缩连续空白。
    /// `[[ ]]` 解析与重复检测都按它比对。
    static func key(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            // 全角 ASCII（U+FF01...U+FF5E）转半角
            if scalar.value >= 0xFF01 && scalar.value <= 0xFF5E {
                out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFEE0)!)
            } else if scalar.value == 0x3000 {
                out.append(" ")
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 正文的稳定哈希。
    ///
    /// 必须跨进程稳定：Swift 的 `Hasher` 每个进程随机加盐，用它存进库里，
    /// 下次启动就永远对不上，只能全量重算。用 SHA256。
    static func bodyHash(_ body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// 标题里禁止出现的字符。理由见设计文档 7.4。
    static let forbiddenTitleScalars: Set<Character> = ["[", "]", "(", ")"]

    /// 校验标题。返回 nil 表示通过，否则返回给用户看的说明。
    static func validateTitle(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "标题不能为空" }
        if t.count < 4 { return "标题至少 4 个字。写成一句可读的断言。" }
        if t.count > 40 { return "标题不超过 40 个字。长标题说明它该拆成两条。" }
        if t.contains(where: { forbiddenTitleScalars.contains($0) }) {
            return "标题不能含 [ ] ( ) 这四个字符"
        }
        if isDateLike(t) { return "标题不要写日期。写成一句断言，例如「稀疏重复优于集中突击」。" }
        if let prefix = bureaucraticPrefix(t) {
            return "标题不要以「\(prefix)」开头。写成一句断言。"
        }
        return nil
    }

    static func isDateLike(_ t: String) -> Bool {
        let patterns = [
            #"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}$"#,
            #"^\d{1,2}月\d{1,2}日$"#,
            #"^\d{4}年\d{1,2}月(\d{1,2}日)?$"#,
            #"^第?\d+章$"#,
            #"^(周|星期)[一二三四五六日天]$"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    private static func bureaucraticPrefix(_ t: String) -> String? {
        ["读书笔记", "会议记录", "会议纪要", "TODO", "待办", "备忘", "随手记"]
            .first { t.hasPrefix($0) }
    }
}

// MARK: - 状态

/// 笔记成熟度。用数字花园的三级术语，与「常绿笔记」的定位一致。
enum NoteStatus: String, Codable, CaseIterable, DatabaseValueConvertible, Sendable {
    case seedling
    case budding
    case evergreen

    var label: String {
        switch self {
        case .seedling: return "幼苗"
        case .budding: return "抽枝"
        case .evergreen: return "常绿"
        }
    }

    var symbolName: String {
        switch self {
        case .seedling: return "leaf"
        case .budding: return "leaf.fill"
        case .evergreen: return "tree"
        }
    }
}

// MARK: - 笔记

/// 一条笔记。正文是唯一真相，其余表都是可重建的索引。
struct Note: Identifiable, Equatable, Hashable, Codable {
    var id: String
    var title: String
    /// 标题的匹配键。见 `TextNormalizer.key`。
    var titleKey: String
    var body: String
    var status: NoteStatus
    var createdAt: Int64
    var updatedAt: Int64
    /// 正文哈希。用于判定是否需要重算索引。
    var bodyHash: String
    /// 笔记类型。见 `NoteTypes`。未注册的类型按 `note` 处理。
    var type: String
    /// 类型段的 JSON 镜像（仅索引用途，真相在 frontmatter）。例如 `{"date":"2026-11-24"}`。
    var meta: String
    /// 未识别的 frontmatter 键的 JSON 镜像。必须原样写回，否则新旧版本互相踩数据。
    var extra: String
    /// 标签的 JSON 镜像。只有 `tagsInBody = false` 的类型（剪藏）用它；其他类型仍从正文扫。
    var tags: String = "[]"

    static func makeId() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let suffix = String(UInt32.random(in: 0..<UInt32.max), radix: 36)
        return "n\(ms)\(suffix)"
    }

    /// 新建一条空笔记。
    static func draft(title: String) -> Note {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return Note(
            id: makeId(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            titleKey: TextNormalizer.key(title),
            body: "",
            status: .seedling,
            createdAt: now,
            updatedAt: now,
            bodyHash: TextNormalizer.bodyHash(""),
            type: NoteTypes.noteID,
            meta: "{}",
            extra: "{}",
            tags: "[]"
        )
    }
}

extension Note {
    var noteType: NoteType { NoteTypes.descriptor(for: type) }

    /// 标签名（解析 `tags`）。顺序保持写入时的顺序，去重。
    var tagNames: [String] {
        guard let data = tags.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return decoded
    }

    mutating func setTagNames(_ names: [String]) {
        var seen = Set<String>()
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert(TextNormalizer.key($0)).inserted }
        guard let data = try? JSONEncoder().encode(cleaned),
              let text = String(data: data, encoding: .utf8)
        else {
            tags = "[]"
            return
        }
        tags = text
    }

    /// 类型段字段（解析 `meta`）。解析失败返回空字典，不抛错。
    var metaFields: [String: String] {
        guard let data = meta.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    var frontmatterExtra: VaultFormat.FrontmatterExtra {
        guard let data = extra.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(VaultFormat.FrontmatterExtra.self, from: data)
        else { return VaultFormat.FrontmatterExtra() }
        return decoded
    }

    mutating func setFrontmatterExtra(_ value: VaultFormat.FrontmatterExtra) {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            extra = "{}"
            return
        }
        extra = text
    }

    /// 写入类型段。键排序后序列化，保证同样的值产出同样的字节。
    mutating func setMetaFields(_ fields: [String: String]) {
        let sorted = Dictionary(uniqueKeysWithValues: fields.sorted { $0.key < $1.key })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sorted),
              let text = String(data: data, encoding: .utf8)
        else {
            meta = "{}"
            return
        }
        meta = text
    }
}

extension Note: FetchableRecord, PersistableRecord {
    static let databaseTableName = "note"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let titleKey = Column(CodingKeys.titleKey)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }
}

// MARK: - 引用

enum LinkStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case resolved
    case dangling
}

/// 从正文解析出的一条有向边。索引，可重建。
struct NoteLink: Identifiable, Equatable, Codable {
    var id: Int64?
    var fromId: String
    var toId: String?
    var rawTarget: String
    var displayText: String
    var anchor: String?
    /// UTF-16 位置，与 `NSTextStorage` 一致。
    var location: Int
    var length: Int
    var status: LinkStatus
}

extension NoteLink: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "link"

    enum Columns {
        static let fromId = Column(CodingKeys.fromId)
        static let toId = Column(CodingKeys.toId)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - 提及（P2 使用）

enum MentionKind: String, Codable, DatabaseValueConvertible, Sendable {
    case exact
    case alias
    case partial
}

/// 正文中出现、但还没变成引用的已有标题。
struct NoteMention: Identifiable, Equatable, Codable {
    var id: Int64?
    var noteId: String
    var targetId: String
    var location: Int
    var length: Int
    var kind: MentionKind
    var dismissed: Bool
}

extension NoteMention: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "mention"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 一处置信度足够的未链接提及，带上下文片段。
struct MentionOccurrence: Identifiable, Equatable, Hashable {
    var id: Int64
    var noteId: String
    var noteTitle: String
    var targetId: String
    var targetTitle: String
    /// UTF-16 位置。
    var location: Int
    var length: Int
    var kind: MentionKind
    var snippet: String
}

/// 按目标聚合的提及。批量面板的一行。
struct MentionGroup: Identifiable, Equatable {
    var targetId: String
    var targetTitle: String
    var occurrences: [MentionOccurrence]
    /// 出现在几篇笔记里。
    var noteCount: Int

    var id: String { targetId }
    var count: Int { occurrences.count }
}

/// 一次正文改写：改前、改后、插入了几处引用。
struct NoteConversion: Identifiable, Equatable {
    var note: Note
    var previousBody: String
    var insertedCount: Int

    var id: String { note.id }
}

/// 改名影响预览。
struct RenameImpact: Identifiable, Equatable {
    var noteId: String
    var noteTitle: String
    var occurrences: Int

    var id: String { noteId }
}

// MARK: - 界面模型

/// 反向链接面板的一行：来源笔记 + 命中处上下文。
struct Backlink: Identifiable, Equatable, Hashable {
    var sourceId: String
    var sourceTitle: String
    var snippet: String
    var isDangling: Bool

    var id: String { sourceId }
}

/// 侧栏列表的一行。
struct NoteSummary: Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var status: NoteStatus
    var backlinkCount: Int
    var outgoingCount: Int
    var snippet: String
    var updatedAt: Int64
    /// 笔记类型。列表按它区分日记与普通笔记，不另建一套模型。
    var type: String = NoteTypes.noteID

    var isJournal: Bool { type == NoteTypes.journalID }
}

/// 侧栏标签列表的一项。
struct TagCount: Identifiable, Equatable, Hashable {
    var name: String
    var count: Int

    var id: String { name }
}

/// `⌘P` Quick Open 的一项。
struct QuickOpenItem: Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var status: NoteStatus
    var backlinkCount: Int
    var tags: [String]
}

/// 侧栏当前看的列表。
enum SidebarScope: Equatable, Hashable {
    case all
    case orphans
    case journal
    case clipUnread
    case clipAll
    case clipArchived
    case tag(String)
    case clipTag(String)
    case search

    var title: String {
        switch self {
        case .all: return "全部"
        case .orphans: return "孤儿笔记"
        case .journal: return "日记"
        case .clipUnread: return "剪藏未读"
        case .clipAll: return "全部剪藏"
        case .clipArchived: return "已归档剪藏"
        case .tag(let name): return "#\(name)"
        case .clipTag(let name): return "#\(name)"
        case .search: return "搜索结果"
        }
    }

    /// 剪藏范围。中间栏换成剪藏阅读视图，列表用 ClipSummary。
    var isClipScope: Bool {
        switch self {
        case .clipUnread, .clipAll, .clipArchived, .clipTag: return true
        default: return false
        }
    }
}

/// `[[` 补全的一项。
struct CompletionItem: Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var status: NoteStatus
    var backlinkCount: Int
    /// 为 true 表示「新建这条笔记」。
    var isCreate: Bool
    /// 目标类型。剪藏项在补全面板里带徽标。
    var type: String = NoteTypes.noteID

    var isClip: Bool { type == NoteTypes.clipID }
}
