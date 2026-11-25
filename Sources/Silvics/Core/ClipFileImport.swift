import Foundation

/// 文件导入：md / txt / html。PDF 见 issue #30，后续版本做。
enum ClipFileImport {

    static let maxBytes = 5 * 1024 * 1024
    static let supportedExtensions: Set<String> = ["md", "markdown", "txt", "html", "htm"]

    enum ImportError: LocalizedError, Equatable {
        case unsupported(String)
        case tooLarge(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "不支持的文件类型：\(ext.isEmpty ? "无扩展名" : ext)"
            case .tooLarge(let bytes): return "文件超过 5 MB（\(bytes) 字节），请改用粘贴正文"
            case .empty: return "文件里没有可用的正文"
            }
        }
    }

    /// 读一个文件，产出剪藏草稿。URL 为空，标题取 frontmatter 或文件名。
    static func draft(from url: URL) throws -> ClipDraft {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ImportError.unsupported(ext) }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? Int, size > maxBytes {
            throw ImportError.tooLarge(size)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw ImportError.tooLarge(data.count) }

        let fileName = url.deletingPathExtension().lastPathComponent
        var draft: ClipDraft

        if ext == "html" || ext == "htm" {
            let article = ClipExtractor.extract(html: ClipExtractor.decode(data))
            draft = ClipDraft(
                title: article.title.isEmpty ? fileName : article.title,
                sourceTitle: article.title,
                site: article.site,
                author: article.author,
                published: article.published,
                body: article.body
            )
        } else {
            var text = ClipExtractor.decode(data)
            var title = ""
            if text.hasPrefix("---") {
                if let frontmatter = try? VaultFormat.parse(text) {
                    title = frontmatter.scalars["title"] ?? ""
                    text = frontmatter.body
                }
            }
            draft = ClipDraft(
                title: title.isEmpty ? fileName : title,
                sourceTitle: title,
                site: "",
                author: "",
                published: "",
                body: text
            )
        }

        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ImportError.empty }
        draft.body = body
        return draft
    }
}
