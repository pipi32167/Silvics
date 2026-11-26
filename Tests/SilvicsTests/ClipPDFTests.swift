import AppKit
import PDFKit
import XCTest
@testable import Silvics

/// 造 PDF 夹具：真画文字，真过 PDFKit，不造假字节。
enum PDFFixture {

    static func data(pages: [String], title: String? = nil) -> Data {
        let buffer = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: buffer as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }

        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont(name: "PingFangSC-Regular", size: 12) ?? NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.black,
                ]
            )
            attributed.draw(in: CGRect(x: 40, y: 640, width: 515, height: 160))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        var out = buffer as Data
        if let title, let doc = PDFDocument(data: out) {
            doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] = title
            if let rewritten = doc.dataRepresentation() { out = rewritten }
        }
        return out
    }

    /// 加密 PDF：写进临时文件，用密码写回，再读字节。
    static func encrypted(pages: [String], password: String) -> Data? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-enc-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let doc = PDFDocument(data: data(pages: pages)) else { return nil }
        let options: [PDFDocumentWriteOption: Any] = [
            PDFDocumentWriteOption.userPasswordOption: password,
            PDFDocumentWriteOption.ownerPasswordOption: password,
        ]
        guard doc.write(to: url, withOptions: options) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func file(_ data: Data, name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-pdf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

    static var chinesePages: [String] {
        [
            String(repeating: "写长文的时候，工具的手感决定写作频率。启动慢、光标跳、预览延迟，都会让人少写一段。\n", count: 2),
            String(repeating: "The friction of the tool decides how often you write. Slow launch, jumping cursor, laggy preview.\n", count: 2),
        ]
    }
}

final class ClipPDFImportTests: XCTestCase {

    func testExtractsChineseAndEnglishPages() throws {
        let extract = try ClipPDFImport.extract(data: PDFFixture.data(pages: PDFFixture.chinesePages))
        XCTAssertEqual(extract.pageCount, 2)
        XCTAssertEqual(extract.usedPages, 2)
        XCTAssertFalse(extract.truncated)
        XCTAssertTrue(extract.body.contains("写作频率"), "中文要能取到")
        XCTAssertTrue(extract.body.contains("friction"), "英文要能取到")
        XCTAssertGreaterThanOrEqual(extract.body.count, ClipPDFImport.minTextLength)
    }

    func testTitleComesFromDocumentAttributesBeforeFileName() throws {
        let named = PDFFixture.data(pages: PDFFixture.chinesePages, title: "写作工具的摩擦成本")
        let draft = try ClipPDFImport.draft(data: named, fileName: "scan-001")
        XCTAssertEqual(draft.title, "写作工具的摩擦成本")
        XCTAssertEqual(draft.sourceTitle, "写作工具的摩擦成本")

        let unnamed = PDFFixture.data(pages: PDFFixture.chinesePages)
        let fallback = try ClipPDFImport.draft(data: unnamed, fileName: "scan-001")
        XCTAssertEqual(fallback.title, "scan-001", "没有文档标题就用文件名")
    }

    func testScannedPDFWithoutTextLayerThrows() {
        let scanned = PDFFixture.data(pages: ["", ""])
        XCTAssertThrowsError(try ClipPDFImport.extract(data: scanned)) { error in
            XCTAssertEqual(error as? ClipPDFImport.PDFError, .scanned(0))
        }
    }

    func testEncryptedPDFThrows() throws {
        let data = try XCTUnwrap(PDFFixture.encrypted(pages: PDFFixture.chinesePages, password: "1234"))
        XCTAssertThrowsError(try ClipPDFImport.extract(data: data)) { error in
            XCTAssertEqual(error as? ClipPDFImport.PDFError, .encrypted)
        }
    }

    func testTruncatesByPageLimit() throws {
        let pages = PDFFixture.chinesePages + [PDFFixture.chinesePages[0] + "\n第三页的独有标记：末尾段。"]
        let extract = try ClipPDFImport.extract(data: PDFFixture.data(pages: pages), maxPages: 2)
        XCTAssertEqual(extract.pageCount, 3)
        XCTAssertEqual(extract.usedPages, 2)
        XCTAssertTrue(extract.truncated)
        XCTAssertFalse(extract.body.contains("末尾段"), "超出页数的内容不取")

        let note = ClipPDFImport.truncationWarning(extract, bytes: 5 * 1024 * 1024)
        XCTAssertEqual(note, "这份 PDF 5.0 MB、共 3 页，只取了前 2 页。")
    }

    func testBrokenDataIsUnreadable() {
        XCTAssertThrowsError(try ClipPDFImport.extract(data: Data("not a pdf".utf8))) { error in
            XCTAssertEqual(error as? ClipPDFImport.PDFError, .unreadable)
        }
    }

    func testNormalizeKeepsParagraphsAndDropsBlankTail() {
        let raw = "第一段第一行  \n第一段第二行\n\n\n\n第二段\n\n"
        XCTAssertEqual(ClipPDFImport.normalize(raw), "第一段第一行\n第一段第二行\n\n第二段")
    }

    /// 中文 PDF 常抽成康熙部首与半角标点，要拉回常用字。
    func testCanonicalFoldsCompatForms() {
        XCTAssertEqual(ClipPDFImport.canonical("写作\u{2F2F}具"), "写作工具", "康熙部首 ⼯ → 工")
        XCTAssertEqual(ClipPDFImport.canonical("⻓⻚⻅⻔"), "长页见门", "部首补充查表")
        XCTAssertEqual(ClipPDFImport.canonical("甲｡乙､丙"), "甲。乙、丙", "半角标点折全角")
        XCTAssertEqual(ClipPDFImport.canonical("甲，乙。"), "甲，乙。", "全角标点不动")
    }

    func testExtractionHasNoCompatForms() throws {
        let extract = try ClipPDFImport.extract(data: PDFFixture.data(pages: PDFFixture.chinesePages))
        XCTAssertTrue(extract.body.contains("工具的手感"), "康熙部首要还原：\(extract.body.prefix(24))")
        XCTAssertTrue(extract.body.contains("的时候，工具"), "全角逗号要留在正文里")
        XCTAssertFalse(extract.body.contains("\u{2F2F}"), "不该残留 ⼯")
        XCTAssertFalse(extract.body.contains("\u{FF61}"))
        XCTAssertTrue(extract.body.contains("friction"), "英文页同一份按页取")
    }

    func testJoinsWrappedLinesBackIntoAParagraph() {
        // 中文折行：上一行没有句末标点，下一行接着读
        let zh = "写长文的时候，工具的手感决定写作频率，启动慢、光标跳、\n预览延迟，都会让人少写一段。"
        XCTAssertEqual(ClipPDFImport.normalize(zh), "写长文的时候，工具的手感决定写作频率，启动慢、光标跳、预览延迟，都会让人少写一段。")

        // 英文折行：接回来时补一个空格
        let en = "When the tool is slow to launch, jumps the cursor, or lags on preview,\nyou write less."
        XCTAssertEqual(ClipPDFImport.normalize(en), "When the tool is slow to launch, jumps the cursor, or lags on preview, you write less.")
    }

    func testDoesNotJoinHeadingsOrBullets() {
        XCTAssertEqual(ClipPDFImport.normalize("写作工具的摩擦成本\n正文第一段够长足够长足够长。"), "写作工具的摩擦成本\n正文第一段够长足够长足够长。")
        XCTAssertEqual(ClipPDFImport.normalize("这是够长的一行正文内容需要保留\n- 列表项"), "这是够长的一行正文内容需要保留\n- 列表项")
        XCTAssertEqual(ClipPDFImport.normalize("这是够长的一行正文内容需要保留\n1. 编号条目"), "这是够长的一行正文内容需要保留\n1. 编号条目")
    }

    func testErrorMessagesAreReadable() {
        XCTAssertNotNil(ClipPDFImport.PDFError.scanned(0).errorDescription)
        XCTAssertTrue(ClipPDFImport.PDFError.encrypted.errorDescription?.contains("密码") ?? false)
        XCTAssertFalse(ClipPDFImport.PDFError.tooLarge(120 * 1024 * 1024).errorDescription?.isEmpty ?? true)
    }
}

final class ClipPDFIngestTests: XCTestCase {

    func testFileImportAcceptsPDF() throws {
        let url = PDFFixture.file(
            PDFFixture.data(pages: PDFFixture.chinesePages, title: "会议纪要"),
            name: "会议纪要.pdf"
        )
        let draft = try ClipFileImport.draft(from: url)
        XCTAssertEqual(draft.title, "会议纪要")
        XCTAssertTrue(draft.body.contains("写作频率"))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testOutcomeFromFileAddsTruncationWarning() throws {
        let url = PDFFixture.file(
            PDFFixture.data(pages: PDFFixture.chinesePages),
            name: "两页.pdf"
        )
        let outcome = try ClipIngest.outcome(fromFile: url)
        XCTAssertEqual(outcome.draft.title, "两页")
        XCTAssertTrue(outcome.warnings.isEmpty, "两页没截断，不该提示")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 网址直连 PDF：地址、站点、标题兜底都要对。
    func testPagePayloadPDFFillsURLAndSite() throws {
        let url = URL(string: "https://example.com/files/report.pdf")!
        let page = ClipPage(url: url, pdf: PDFFixture.data(pages: PDFFixture.chinesePages))
        let outcome = try ClipIngest.outcome(fromPage: page)
        XCTAssertEqual(outcome.draft.url, "https://example.com/files/report.pdf")
        XCTAssertEqual(outcome.draft.site, "example.com")
        XCTAssertEqual(outcome.draft.title, "report", "没有文档标题就用网址里的文件名")
    }

    func testScannedPDFFromURLSurfacesPDFError() {
        let url = URL(string: "https://example.com/scan.pdf")!
        let page = ClipPage(url: url, pdf: PDFFixture.data(pages: [""]))
        XCTAssertThrowsError(try ClipIngest.outcome(fromPage: page)) { error in
            XCTAssertEqual(error as? ClipPDFImport.PDFError, .scanned(0))
        }
    }

    func testPDFFileNameStripsExtensionAndDecodes() {
        XCTAssertEqual(
            ClipIngest.pdfFileName(for: URL(string: "https://a.com/d/%E4%BC%9A%E8%AE%AE.pdf")!),
            "会议"
        )
        XCTAssertEqual(ClipIngest.pdfFileName(for: URL(string: "https://a.com")!), "a.com")
    }
}

/// 自带响应头的桩，比 ConflictTests 那个多一个 Content-Type。
final class PDFStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let respond = Self.respond else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, headers, data) = respond(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PDFStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class ClipPDFFetchTests: XCTestCase {

    private let pdf = PDFFixture.data(pages: PDFFixture.chinesePages)

    override func tearDown() {
        PDFStubURLProtocol.respond = nil
        super.tearDown()
    }

    func testURLReturnsPDFWhenServerSaysApplicationPDF() async throws {
        PDFStubURLProtocol.respond = { _ in
            (200, ["Content-Type": "application/pdf"], self.pdf)
        }
        let result = await ClipFetchService.fetch(
            raw: "https://example.com/a.pdf", timeout: 5, session: PDFStubURLProtocol.makeSession()
        )
        guard case .success(let page) = result else { return XCTFail("应该抓到 PDF") }
        XCTAssertTrue(page.isPDF)
        XCTAssertEqual(page.html, "", "PDF 没有 HTML 正文")
        let draft = try ClipIngest.outcome(fromPage: page).draft
        XCTAssertTrue(draft.body.contains("写作频率"))
    }

    func testURLReturnsPDFWhenServerSaysOctetStream() async throws {
        PDFStubURLProtocol.respond = { _ in
            (200, ["Content-Type": "application/octet-stream"], self.pdf)
        }
        let result = await ClipFetchService.fetch(
            raw: "https://example.com/download?id=7", timeout: 5, session: PDFStubURLProtocol.makeSession()
        )
        guard case .success(let page) = result else { return XCTFail("octet-stream 也要认 PDF") }
        XCTAssertTrue(page.isPDF)
    }

    func testURLStillReturnsHTMLForPages() async throws {
        let html = "<html><head><meta property=\"og:title\" content=\"题目\"></head><body><article><p>正文段落。</p></article></body></html>"
        PDFStubURLProtocol.respond = { _ in
            (200, ["Content-Type": "text/html; charset=utf-8"], Data(html.utf8))
        }
        let result = await ClipFetchService.fetch(
            raw: "https://example.com/post", timeout: 5, session: PDFStubURLProtocol.makeSession()
        )
        guard case .success(let page) = result else { return XCTFail("应该抓到网页") }
        XCTAssertFalse(page.isPDF)
        XCTAssertTrue(page.html.contains("正文段落"))
    }

    func testOversizedPDFIsRejectedWithItsOwnMessage() async {
        let huge = Data(repeating: 0x25, count: ClipPDFImport.maxDownloadBytes + 1024)
        PDFStubURLProtocol.respond = { _ in
            (200, ["Content-Type": "application/pdf"], huge)
        }
        let result = await ClipFetchService.fetch(
            raw: "https://example.com/huge.pdf", timeout: 5, session: PDFStubURLProtocol.makeSession()
        )
        guard case .failure(let error) = result else { return XCTFail("超大 PDF 应被拒") }
        XCTAssertEqual(error, .pdfTooLarge(huge.count))
        XCTAssertTrue(error.errorDescription?.contains("20 MB") ?? false)
    }

    func testPDFDetectionByMagicBytesWins() {
        XCTAssertTrue(ClipFetchService.isPDF(
            data: self.pdf,
            contentType: "text/html",
            url: URL(string: "https://example.com/x")!
        ), "魔数优先，服务器报错类型也认")
        XCTAssertFalse(ClipFetchService.isPDF(
            data: Data("<html><body>hi</body></html>".utf8),
            contentType: "text/html",
            url: URL(string: "https://example.com/x.pdf")!
        ))
    }
}
