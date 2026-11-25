import Foundation

/// 剪藏类型段的字段名。真相在 frontmatter 的 `clip:` 段，`note.meta` 只是镜像。
///
/// 不存派生值：字数、正文哈希、地址归一化结果都算出来，不进文件。
enum ClipFields {
    static let url = "url"
    static let site = "site"
    static let author = "author"
    static let published = "published"
    static let sourceTitle = "sourceTitle"
    static let summary = "summary"
    static let status = "clipStatus"
    static let aiState = "aiState"
    static let aiModel = "aiModel"

    /// 写进 frontmatter、被识别为已知键的字段。其余键按未知原样保留。
    static let allKeys = [url, site, author, published, sourceTitle, summary, status, aiState, aiModel]
}

/// 剪藏的阅读状态。与概念笔记的成熟度 `NoteStatus` 无关。
enum ClipStatus: String, Codable, CaseIterable, Sendable {
    case unread
    case read
    case archived

    var label: String {
        switch self {
        case .unread: return "未读"
        case .read: return "已读"
        case .archived: return "已归档"
        }
    }
}

/// 剪藏整理（标题、摘要、标签）的状态。
enum ClipAIState: String, Codable, Sendable {
    case done
    case pending
    case failed

    var label: String {
        switch self {
        case .done: return "已整理"
        case .pending: return "待整理"
        case .failed: return "整理失败"
        }
    }
}

/// 剪藏地址的归一化。只做影响「同一个网页」的部分：协议小写、主机小写、去尾斜杠、去追踪参数。
///
/// 存进 `clip.url` 的就是归一化结果，查重也用它，所以不需要单独的 `urlKey` 列。
enum ClipURL {

    /// 常见的追踪参数。命中就删，不影响页面内容。
    static let trackingKeys: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "spm", "from", "share_token", "ref", "ref_src",
    ]

    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }

        var out = components
        out.scheme = scheme
        out.host = host
        out.fragment = nil
        if let items = out.queryItems, !items.isEmpty {
            let kept = items.filter { !trackingKeys.contains($0.name.lowercased()) }
            out.queryItems = kept.isEmpty ? nil : kept
        }
        var text = out.string ?? trimmed
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// 剪藏列表的一行。正文不进列表，避免每次查询搬运长文本。
struct ClipSummary: Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var site: String
    var url: String
    var summary: String
    var status: ClipStatus
    var aiState: ClipAIState
    var tags: [String]
    var createdAt: Int64
    var charCount: Int
}

/// 新建剪藏的输入。抓取、粘贴、文件导入都产出这一份。
struct ClipDraft {
    var url: String = ""
    var title: String = ""
    /// 原文标题。与 `title` 不同：`title` 是最终落库的标题，可能被清洗或追加来源。
    var sourceTitle: String = ""
    var site: String = ""
    var author: String = ""
    var published: String = ""
    var body: String
    var summary: String = ""
    var tags: [String] = []
    var status: ClipStatus = .unread
    var aiState: ClipAIState = .pending
    var aiModel: String = ""
}

enum ClipError: LocalizedError, Equatable {
    case invalidURL(String)
    case emptyBody
    case duplicateURL(noteId: String, title: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw): return "地址不是 http(s) 链接：\(raw)"
        case .emptyBody: return "正文是空的，没有可保存的内容"
        case .duplicateURL(_, let title): return "这个地址已经剪藏过：《\(title)》"
        }
    }
}
