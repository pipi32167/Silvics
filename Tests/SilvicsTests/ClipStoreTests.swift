import XCTest
@testable import Silvics

final class ClipTitleTests: XCTestCase {

    func testCleansMarkdownAndForbiddenCharacters() {
        let title = ClipTitle.clean("## **稀疏重复** 优于 [集中](突击)")
        XCTAssertEqual(title, "稀疏重复 优于 ［集中］（突击）")
    }

    func testTruncatesLongTitle() {
        let raw = String(repeating: "长", count: 80)
        let title = ClipTitle.clean(raw)
        XCTAssertEqual(title.count, ClipTitle.maxLength + 1, "60 字加一个省略号")
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testFallbackFromBody() {
        let body = "\n\n# 第一段就是标题\n第二段。"
        XCTAssertEqual(ClipTitle.fromBody(body), "第一段就是标题")
    }

    func testDateLikeTitleGetsSourceSuffix() {
        let title = ClipTitle.finalize(raw: "2026-11-24", source: "少数派", body: "正文") { _ in false }
        XCTAssertEqual(title, "2026-11-24 · 少数派")
    }

    func testDuplicateTitleGetsSourceThenIndex() {
        var taken: Set<String> = [TextNormalizer.key("稀疏重复优于集中突击")]
        let first = ClipTitle.finalize(raw: "稀疏重复优于集中突击", source: "少数派", body: "正文") {
            taken.contains(TextNormalizer.key($0))
        }
        XCTAssertEqual(first, "稀疏重复优于集中突击 · 少数派")
        taken.insert(TextNormalizer.key(first))

        let second = ClipTitle.finalize(raw: "稀疏重复优于集中突击", source: "少数派", body: "正文") {
            taken.contains(TextNormalizer.key($0))
        }
        XCTAssertEqual(second, "稀疏重复优于集中突击 · 少数派 (2)")
    }

    func testEmptyEverythingFallsBackToUnnamed() {
        let title = ClipTitle.finalize(raw: "", source: "", body: "") { _ in false }
        XCTAssertTrue(title.hasPrefix("未命名剪藏 · "))
        XCTAssertFalse(title.isEmpty)
    }
}

final class ClipStoreTests: XCTestCase {

    private var vault: TempVault!
    private var db: AppDatabase!
    private var repo: GRDBNoteRepository!

    override func setUpWithError() throws {
        vault = TempVault("clip-store")
        db = try AppDatabase.makeInMemory()
        repo = vault.repo(db)
    }

    override func tearDown() {
        repo = nil
        db = nil
        vault = nil
    }

    private func draft(
        title: String,
        url: String = "",
        site: String = "",
        body: String = "这是一篇剪藏正文，长度足够参与检索。",
        tags: [String] = []
    ) -> ClipDraft {
        ClipDraft(
            url: url,
            title: title,
            sourceTitle: title,
            site: site,
            body: body,
            tags: tags
        )
    }

    func testCreateClipWritesFileAndDefaults() throws {
        let note = try repo.createClip(draft(title: "稀疏重复优于集中突击", url: "https://example.com/a?utm_source=x"))

        XCTAssertEqual(note.type, NoteTypes.clipID)
        let file = vault.url.appendingPathComponent("clips/\(note.id).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let summary = try XCTUnwrap(try repo.clipSummaries().first)
        XCTAssertEqual(summary.status, .unread)
        XCTAssertEqual(summary.aiState, .pending)
        XCTAssertEqual(summary.url, "https://example.com/a", "追踪参数要去掉")
        XCTAssertEqual(try repo.clipUnreadCount(), 1)
    }

    func testDuplicateURLIsRejected() throws {
        let first = try repo.createClip(draft(title: "稀疏重复优于集中突击", url: "https://example.com/a"))
        XCTAssertThrowsError(try repo.createClip(draft(title: "另一个标题", url: "https://example.com/a/"))) { error in
            XCTAssertEqual(error as? ClipError, .duplicateURL(noteId: first.id, title: first.title))
        }
    }

    func testInvalidURLIsRejected() {
        XCTAssertThrowsError(try repo.createClip(draft(title: "稀疏重复优于集中突击", url: "file:///etc/passwd"))) { error in
            XCTAssertEqual(error as? ClipError, .invalidURL("file:///etc/passwd"))
        }
    }

    func testSameBodyIsOnlyAHint() throws {
        let body = "完全相同的正文，用于提示已剪藏过。"
        _ = try repo.createClip(draft(title: "第一篇", body: body))
        let sameHash = TextNormalizer.bodyHash(body)
        XCTAssertNotNil(try repo.clipID(forBodyHash: sameHash))

        // 只提示，不拦：第二篇照样能存。
        let second = try repo.createClip(draft(title: "第二篇", body: body))
        XCTAssertEqual(second.type, NoteTypes.clipID)
    }

    func testStatusTransitionsAndListFiltering() throws {
        let note = try repo.createClip(draft(title: "稀疏重复优于集中突击"))
        _ = try repo.updateClipStatus(id: note.id, status: .read)
        XCTAssertEqual(try repo.clipUnreadCount(), 0)
        XCTAssertEqual(try repo.clipSummaries(status: .read).count, 1)

        _ = try repo.updateClipStatus(id: note.id, status: .archived)
        XCTAssertEqual(try repo.clipSummaries(status: .archived).count, 1)

        // 状态也进 frontmatter
        let file = vault.url.appendingPathComponent("clips/\(note.id).md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("clipStatus: archived"))
    }

    func testClipTagsFilterAndIndex() throws {
        let note = try repo.createClip(draft(title: "稀疏重复优于集中突击", tags: ["记忆", "学习方法"]))
        XCTAssertEqual(try repo.clipSummaries(tagged: "记忆").map(\.id), [note.id])
        XCTAssertEqual(Set(try repo.allTags(types: [NoteTypes.clipID]).map(\.name)), ["记忆", "学习方法"])
        XCTAssertTrue(try repo.allTags().isEmpty, "主标签列表不出现剪藏标签")
    }

    func testReferenceCountAndDanglingAfterDelete() throws {
        let clip = try repo.createClip(draft(title: "稀疏重复优于集中突击"))
        let concept = try repo.create(title: "间隔重复对抗遗忘")
        var withBody = concept
        withBody.body = "参考 [[稀疏重复优于集中突击]]。"
        _ = try repo.save(withBody)

        XCTAssertEqual(try repo.referenceCount(to: clip.id), 1)

        try repo.delete(id: clip.id)
        let links = try repo.outgoing(from: concept.id)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.status, .dangling)
    }

    func testClipTitleAvoidsJournalDateCollision() throws {
        let journal = try repo.journalNote(on: "2026-11-24", using: [])
        let clip = try repo.createClip(draft(title: "2026-11-24", site: "少数派"))
        XCTAssertEqual(clip.title, "2026-11-24 · 少数派")
        XCTAssertNotEqual(clip.titleKey, journal.titleKey)
        XCTAssertNotNil(try repo.journalNote(on: "2026-11-24", using: []))
    }

    func testTitleFromBodyWhenSourceMissing() throws {
        let note = try repo.createClip(draft(title: "", body: "# 从正文提取的标题\n\n正文内容。"))
        XCTAssertEqual(note.title, "从正文提取的标题")
    }
}

final class ClipExtractorTests: XCTestCase {

    func testStripsScriptStyleAndNav() {
        let html = """
        <html><head><title>页面标题</title></head>
        <body>
          <nav>导航条目</nav>
          <script>var x = 1;</script>
          <style>body{color:red}</style>
          <article><h1>正文标题</h1><p>第一段。</p><p>第二段带 <b>重点</b>。</p></article>
          <footer>版权</footer>
        </body></html>
        """
        let article = ClipExtractor.extract(html: html)
        XCTAssertEqual(article.title, "页面标题")
        XCTAssertFalse(article.body.contains("导航条目"))
        XCTAssertFalse(article.body.contains("var x"))
        XCTAssertFalse(article.body.contains("color:red"))
        XCTAssertTrue(article.body.contains("## 正文标题"))
        XCTAssertTrue(article.body.contains("第二段带 重点"))
        XCTAssertFalse(article.body.contains("版权"))
    }

    func testListsAndEntities() {
        let html = """
        <article>
          <ul><li>第一项</li><li>第二项 &amp; 更多</li></ul>
          <p>引号 &ldquo;测试&rdquo; 与数字 &#65;</p>
        </article>
        """
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertTrue(body.contains("- 第一项"))
        XCTAssertTrue(body.contains("- 第二项 & 更多"))
        XCTAssertTrue(body.contains("“测试”"))
        XCTAssertTrue(body.contains("A"))
    }

    func testMetaInformation() {
        let html = """
        <html><head>
          <meta property="og:title" content="原站标题">
          <meta property="og:site_name" content="少数派">
          <meta name="author" content="张三">
          <meta property="article:published_time" content="2026-11-20T10:00:00Z">
        </head><body><article><p>正文。</p></article></body></html>
        """
        let article = ClipExtractor.extract(html: html)
        XCTAssertEqual(article.title, "原站标题")
        XCTAssertEqual(article.site, "少数派")
        XCTAssertEqual(article.author, "张三")
        XCTAssertEqual(article.published, "2026-11-20T10:00:00Z")
    }

    func testFallsBackToBodyWhenNoArticle() {
        let html = "<html><body><p>只有一段正文，没有 article 标签。</p></body></html>"
        XCTAssertEqual(ClipExtractor.text(fromHTML: html), "只有一段正文，没有 article 标签。")
    }

    func testDecodesGB18030() throws {
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let original = "中文编码测试"
        let data = try XCTUnwrap(original.data(using: encoding))
        XCTAssertEqual(ClipExtractor.decode(data), original)
    }

    func testCollapsesBlankLines() {
        let body = ClipExtractor.normalizeWhitespace("一\n\n\n\n二\n\n三")
        XCTAssertEqual(body, "一\n\n二\n\n三")
    }
}

final class ClipFileImportTests: XCTestCase {

    func testImportsMarkdownWithFrontmatter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("草稿.md")
        try """
        ---
        title: 文件里的标题
        ---
        正文第一段。

        正文第二段。
        """.write(to: file, atomically: true, encoding: .utf8)

        let draft = try ClipFileImport.draft(from: file)
        XCTAssertEqual(draft.title, "文件里的标题")
        XCTAssertEqual(draft.body, "正文第一段。\n\n正文第二段。")
        try? FileManager.default.removeItem(at: dir)
    }

    func testImportsPlainTextUsingFileName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("我的笔记.txt")
        try "只有正文，没有标题。".write(to: file, atomically: true, encoding: .utf8)

        let draft = try ClipFileImport.draft(from: file)
        XCTAssertEqual(draft.title, "我的笔记")
        XCTAssertEqual(draft.body, "只有正文，没有标题。")
        try? FileManager.default.removeItem(at: dir)
    }

    func testRejectsUnsupportedFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("x.docx")
        XCTAssertThrowsError(try ClipFileImport.draft(from: file)) { error in
            XCTAssertEqual(error as? ClipFileImport.ImportError, .unsupported("docx"))
        }
    }
}
