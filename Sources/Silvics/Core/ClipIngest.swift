import Foundation

/// 把三种输入（网页、粘贴、文件）统一成 `ClipDraft`。
///
/// 这里只做「取到正文 + 元信息」，调模型与落库分别由 `ClipAIService`、`ClipStore` 负责。
enum ClipIngest {

    /// 一次导入的产物：草稿加要告知用户的提示。
    struct Outcome: Equatable {
        var draft: ClipDraft
        var warnings: [String] = []
    }

    enum IngestError: LocalizedError, Equatable {
        case emptyBody
        case noTitle

        var errorDescription: String? {
            switch self {
            case .emptyBody: return "没有取到正文，请改用粘贴正文"
            case .noTitle: return "没能确定标题，请手动填写"
            }
        }
    }

    static func draft(fromPage page: ClipPage) throws -> ClipDraft {
        try outcome(fromPage: page).draft
    }

    /// 网页或 PDF。PDF 走 `ClipPDFImport` 取文字层。
    static func outcome(fromPage page: ClipPage) throws -> Outcome {
        switch page.payload {
        case .pdf(let data):
            return try outcome(
                fromPDF: data,
                fileName: pdfFileName(for: page.url),
                url: page.url.absoluteString,
                site: page.url.host ?? ""
            )
        case .html(let html):
            let article = ClipExtractor.extract(html: html)
            let body = article.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw IngestError.emptyBody }

            let site = article.site.isEmpty ? (page.url.host ?? "") : article.site
            return Outcome(draft: ClipDraft(
                url: page.url.absoluteString,
                title: article.title,
                sourceTitle: article.title,
                site: site,
                author: article.author,
                published: article.published,
                body: body
            ))
        }
    }

    /// PDF 字节直接来自下载或文件。
    static func outcome(
        fromPDF data: Data,
        fileName: String,
        url: String = "",
        site: String = ""
    ) throws -> Outcome {
        let value = try ClipPDFImport.extract(data: data)
        let title = value.title.isEmpty ? fileName : value.title
        let draft = ClipDraft(
            url: url,
            title: title,
            sourceTitle: title,
            site: site,
            author: value.author,
            published: "",
            body: value.body
        )
        var warnings: [String] = []
        if let note = ClipPDFImport.truncationWarning(value, bytes: data.count) {
            warnings.append(note)
        }
        return Outcome(draft: draft, warnings: warnings)
    }

    /// 从网址里猜 PDF 的文件名，用来当标题兜底。
    static func pdfFileName(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
            .removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? (url.host ?? "未命名剪藏") : name
    }

    static func draft(fromText body: String, title: String = "", url: String = "") throws -> ClipDraft {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IngestError.emptyBody }
        return ClipDraft(url: url, title: title, sourceTitle: title, body: text)
    }

    static func draft(fromFile url: URL) throws -> ClipDraft {
        try outcome(fromFile: url).draft
    }

    /// 文件入口：PDF 要带上截断提示，其他类型照旧。
    static func outcome(fromFile url: URL) throws -> Outcome {
        guard url.pathExtension.lowercased() == "pdf" else {
            return Outcome(draft: try ClipFileImport.draft(from: url))
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= ClipPDFImport.maxFileBytes else {
            throw ClipPDFImport.PDFError.tooLarge(data.count)
        }
        return try outcome(
            fromPDF: data,
            fileName: url.deletingPathExtension().lastPathComponent
        )
    }

    /// 正文太短时给的提示。返回 nil 表示不用提示。
    static func shortBodyWarning(_ body: String) -> String? {
        guard body.count < ClipExtractor.minBodyLength else { return nil }
        return "抓到的正文只有 \(body.count) 字，可能被登录墙挡住了。可以手动补正文。"
    }
}
