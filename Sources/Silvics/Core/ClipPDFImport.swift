import Foundation
import PDFKit

/// PDF 剪藏：按页取文字层，页与页之间空一行。
///
/// 只做「取到能读的正文」，不做 OCR。扫描件没有文字层时抛 `scanned`，
/// 由界面提示改走粘贴。加密件不解密。
enum ClipPDFImport {

    /// 本地文件硬上限。超过直接拒，避免把巨文件读进内存。
    static let maxFileBytes = 100 * 1024 * 1024
    /// URL 下载上限。PDF 常见十几兆，比文本宽松。
    static let maxDownloadBytes = 20 * 1024 * 1024
    /// 单次最多取多少页。超出按页截断并提示。
    static let maxPages = 60
    /// 文字层少于这个字数就当扫描件。与 `ClipExtractor.minBodyLength` 同源。
    static let minTextLength = ClipExtractor.minBodyLength

    struct Extract: Equatable {
        var title: String = ""
        var author: String = ""
        var body: String = ""
        var pageCount: Int = 0
        var usedPages: Int = 0

        /// 因为页数上限被截断了。
        var truncated: Bool { usedPages < pageCount }
    }

    enum PDFError: LocalizedError, Equatable {
        case unreadable
        case encrypted
        case tooLarge(Int)
        case tooLargeDownload(Int)
        case scanned(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return "这个 PDF 打不开，文件可能损坏"
            case .encrypted: return "这份 PDF 需要密码，读不到文字层。请手动粘贴正文"
            case .tooLarge(let bytes): return "PDF 超过 100 MB（\(Self.mb(bytes))），请拆分后再导入"
            case .tooLargeDownload(let bytes): return "PDF 超过 20 MB（\(Self.mb(bytes))），请先下载再拖进来"
            case .scanned(let chars):
                return chars == 0
                    ? "这是扫描件，没有文字层。请手动粘贴正文"
                    : "只取到 \(chars) 字，可能是扫描件或图片版。请手动粘贴正文"
            case .empty: return "这个 PDF 没有页面"
            }
        }

        private static func mb(_ bytes: Int) -> String {
            String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
        }
    }

    /// 取文字。`maxPages` 可调，测试用来造截断场景。
    static func extract(data: Data, maxPages: Int = maxPages) throws -> Extract {        guard data.count <= maxFileBytes else { throw PDFError.tooLarge(data.count) }
        guard let doc = PDFDocument(data: data) else { throw PDFError.unreadable }
        guard !doc.isLocked else { throw PDFError.encrypted }
        guard doc.pageCount > 0 else { throw PDFError.empty }

        let limit = min(doc.pageCount, max(1, maxPages))
        var pages: [String] = []
        var used = 0
        for index in 0..<limit {
            guard let page = doc.page(at: index) else { continue }
            used = index + 1
            let text = normalize(page.string ?? "")
            if !text.isEmpty { pages.append(text) }
        }

        let body = pages.joined(separator: "\n\n")
        guard body.count >= minTextLength else { throw PDFError.scanned(body.count) }

        let attributes = doc.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String) ?? ""

        return Extract(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body,
            pageCount: doc.pageCount,
            usedPages: used
        )
    }

    /// 取到草稿。标题：文档属性标题 → 文件名。
    static func draft(data: Data, fileName: String, url: String = "", site: String = "") throws -> ClipDraft {
        let value = try extract(data: data)
        let title = value.title.isEmpty ? fileName : value.title
        return ClipDraft(
            url: url,
            title: title,
            sourceTitle: value.title.isEmpty ? fileName : value.title,
            site: site,
            author: value.author,
            published: "",
            body: value.body
        )
    }

    /// 读到截断提示文案。返回 nil 表示没被截断。
    static func truncationWarning(_ value: Extract, bytes: Int) -> String? {
        guard value.truncated else { return nil }
        return "这份 PDF \(sizeText(bytes))、共 \(value.pageCount) 页，只取了前 \(value.usedPages) 页。"
    }

    /// 体积文案。不到 1 MB 说 KB，免得写成「0.0 MB」。
    static func sizeText(_ bytes: Int) -> String {
        if bytes < 1024 * 1024 {
            return "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
        }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    /// 统一的字形。中文 PDF 常把「工具」抽成康熙部首、把「，。」抽成半角形式，
    /// 不折回来会「看起来像中文、搜不到、也不好看」。
    ///
    /// 只折两类字符，其它原样保留：整体跑 NFKC 会把全角逗号句号也改成 ASCII，
    /// 中文正文就散了。
    static func canonical(_ raw: String) -> String {
        var out = String()
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x2F00...0x2FDF, 0xF900...0xFAFF:
                // 康熙部首、CJK 兼容汉字：NFKC 能直接拆成常用字。
                out += String(Character(scalar)).precomposedStringWithCompatibilityMapping
            case 0xFF61...0xFF65:
                out.append(Self.halfWidthPunctuation[Character(scalar)] ?? Character(scalar))
            case 0x2E80...0x2EFF:
                // CJK 部首补充没有兼容分解，只能查表。
                out.append(Self.radicalSupplement[Character(scalar)] ?? Character(scalar))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// `｡｢｣､･` 五个半角标点。
    private static let halfWidthPunctuation: [Character: Character] = [
        "｡": "。", "｢": "「", "｣": "」", "､": "、", "･": "・",
    ]

    /// CJK 部首补充（U+2E80–U+2EFF）里常见的简体部首。没兼容分解，只能手写。
    private static let radicalSupplement: [Character: Character] = [
        "⻓": "长", "⻚": "页", "⻅": "见", "⻔": "门", "⻢": "马", "⻋": "车",
        "⻛": "风", "⻜": "飞", "⻉": "贝", "⻘": "青", "⻥": "鱼", "⻦": "鸟",
        "⻰": "龙", "⻨": "麦", "⻩": "黄", "⻮": "齿", "⻲": "龟", "⻤": "鬼",
    ]

    /// 每页内部收尾：去行尾空白、把连续空行压成一个、把折行接回一段。
    ///
    /// PDF 里的行是排版折行（一段被切成好几行），不接回来读起来是碎的；
    /// 但标题、列表项、以句末标点结尾的行不接。
    static func normalize(_ raw: String) -> String {
        var lines: [String] = []
        var previousBlank = false
        for line in canonical(raw).split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                if !previousBlank, !lines.isEmpty { lines.append("") }
                previousBlank = true
            } else {
                lines.append(text)
                previousBlank = false
            }
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }

        // 按空行分段落，段内接折行。
        var paragraphs: [[String]] = [[]]
        for line in lines {
            if line.isEmpty { paragraphs.append([]) } else { paragraphs[paragraphs.count - 1].append(line) }
        }
        return paragraphs
            .map { reflow($0).joined(separator: "\n") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// 句末标点。行尾是这些就不接下一行。
    private static let sentenceEnd: Set<Character> = [
        "。", "．", ".", "！", "!", "？", "?", "…",
        "）", "】", "」", "』", "”", "’", ")", "]",
    ]

    /// 列表或小节标记，行首是这些就是新的一条。
    private static let bulletPrefix: Set<Character> = ["•", "·", "-", "–", "—", "*", "▸", "■", "□", "○"]

    /// 段内把排版折行接回去。
    static func reflow(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            guard let previous = out.last, shouldJoin(previous: previous, next: line) else {
                out.append(line)
                continue
            }
            let separator = (previous.last?.isASCII == true && line.first?.isASCII == true) ? " " : ""
            out[out.count - 1] = previous + separator + line
        }
        return out
    }

    private static func shouldJoin(previous: String, next: String) -> Bool {
        guard let last = previous.last, let first = next.first else { return false }
        if sentenceEnd.contains(last) { return false }
        if bulletPrefix.contains(first) { return false }
        // 「1. 第一条」这种编号行
        if first.isNumber, next.dropFirst().first == "." { return false }
        // 短行当标题或图注，不接
        if previous.count < 12 { return false }
        // 拉丁句首大写：很可能真是新句子
        if last.isASCII, last.isLetter, first.isUppercase { return false }
        if last.isCJKIdeograph { return true }
        if first.isCJKIdeograph { return true }
        return first.isLowercase || first.isNumber
    }
}

extension Character {
    /// 汉字或中文标点。用来决定接行时加不加空格。
    var isCJKIdeograph: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0x3000...0x303F).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
    }
}
