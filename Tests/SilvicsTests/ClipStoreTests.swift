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

    func testDropsSiteChromeAroundArticleBody() {
        let html = """
        <html><head><title>站点标题</title></head><body>
          <nav class="site-nav"><a href="/">首页</a><a href="/hot">热门</a></nav>
          <article class="normal-article">
            <div class="article__header">
              <span>作者 关注</span>
              <div class="article__share">微信扫码分享 分享收藏举报</div>
            </div>
            <div class="article-body">
              <h4>Matrix 首页推荐</h4>
              <p>Matrix 是少数派的写作社区，我们主张分享真实的产品体验。</p>
              <p>文章代表作者个人观点，少数派仅对标题和排版略作修改。</p>
              <h2>正文标题</h2>
              <p>第一段正文。</p>
              <p>第二段正文。</p>
              <h2>相关阅读</h2>
              <ul>
                <li><a href="/a">推荐文章一</a></li>
                <li><a href="/b">推荐文章二</a></li>
                <li><a href="/c">推荐文章三</a></li>
              </ul>
            </div>
            <div class="article__footer">标签</div>
            <div class="post__comments"><p>评论区内容</p></div>
          </article>
        </body></html>
        """
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertTrue(body.contains("## 正文标题"))
        XCTAssertTrue(body.contains("第一段正文。"))
        XCTAssertTrue(body.contains("第二段正文。"))
        for noise in ["作者 关注", "微信扫码", "分享收藏", "Matrix 是少数派", "文章代表作者", "相关阅读", "推荐文章", "评论区", "标签"] {
            XCTAssertFalse(body.contains(noise), "不该保留：\(noise)\n\(body)")
        }
    }

    func testDropsLinkFarmWithoutNoiseClassName() {
        let links = (1...12).map { "<li><a href=\"/p/\($0)\">推荐文章 \($0)</a></li>" }.joined()
        let html = "<html><body><article><div class=\"article-body\"><p>正文一。</p><div class=\"links\"><ul>\(links)</ul></div><p>正文二。</p></div></article></body></html>"
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertTrue(body.contains("正文一。"))
        XCTAssertTrue(body.contains("正文二。"))
        XCTAssertFalse(body.contains("推荐文章"))
    }

    func testKeepsCodeBlock() {
        let html = "<html><body><article><div class=\"article-body\"><p>说明。</p><pre><code>let x = 1 &lt; 2</code></pre></div></article></body></html>"
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertTrue(body.contains("```"))
        XCTAssertTrue(body.contains("let x = 1 < 2"))
    }

    func testRemovesEditLinksAndNavLines() {
        let html = "<html><body><article><div class=\"article-body\"><h2>标题[编辑]</h2><p>正文。</p><p>上一页</p><p>下一页</p></div></article></body></html>"
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertFalse(body.contains("[编辑]"))
        XCTAssertFalse(body.contains("上一页"))
        XCTAssertFalse(body.contains("下一页"))
    }

    func testDropsAccountNameDuplicatedByPublishLine() {
        let html = """
        <html><body><article class="article-body">
          <h1>中国银行，发布风险提示</h1>
          <p>长安街知事</p>
          <p>2026-11-26 07:49发布于北京长安街知事官方账号</p>
          <p>问AI · 国际金价下跌意味着什么？</p>
          <p>近日，国际金价连续下行。11月25日，现货黄金价格一度跌破3500美元/盎司整数关口。</p>
        </article></body></html>
        """
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertFalse(body.contains("长安街知事"))
        XCTAssertFalse(body.contains("发布于"))
        XCTAssertFalse(body.contains("问AI"))
        XCTAssertTrue(body.contains("近日，国际金价连续下行"))
    }

    func testDropsProductionCreditsAndRelatedBlocks() {
        let html = """
        <html><body><article class="article-body">
          <p>2026-11-24 09:33:15</p>
          <p>2026年11月24日 09:33　来源：中国新闻网</p>
          <p>大字体</p><p>小字体</p>
          <p>中新网11月24日电 题：正文从这里开始。</p>
          <p>第一段正文。</p>
          <p>｜总策划：俞岚</p>
          <p>｜策划：周锐</p>
          <p>【编辑:曹子健】</p>
          <p>更多精彩内容请进入国内新闻</p>
          <h2>国内新闻精选：</h2>
          <ul><li><a href="/a">推荐文章一</a></li><li><a href="/b">推荐文章二</a></li></ul>
        </article></body></html>
        """
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertTrue(body.contains("第一段正文。"))
        for noise in ["09:33", "大字体", "小字体", "总策划", "【编辑", "更多精彩内容", "国内新闻精选", "推荐文章"] {
            XCTAssertFalse(body.contains(noise), "不该保留：\(noise)\n\(body)")
        }
    }

    func testFallsBackToDescriptionForJSRenderedPage() {
        let html = """
        <html><head>
          <meta name="description" content="90多年前，中国工农红军开启了一场伟大远征，是什么支撑着这支队伍闯过一道道生死关，最终走向胜利？">
        </head><body><article class="article-body">
          <p>增值电信业务经营许可证：沪B2-2017116</p>
          <p>© 2014-2026 上海东方报业有限公司</p>
        </article></body></html>
        """
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertTrue(body.contains("90多年前"))
        XCTAssertFalse(body.contains("许可证"))
        XCTAssertFalse(body.contains("东方报业"))
    }

    func testRootClassListDoesNotNukeWholePage() {
        let html = """
        <html class="client-nojs vector-feature-language-in-header-enabled vector-toc-available">
        <body class="skin-theme-clientpref-day sticky-header-enabled">
          <div class="mw-parser-output"><p>这一整页都应该保留，不能因为 html 的 class 里有 header/sticky 就删掉。</p></div>
        </body></html>
        """
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertTrue(body.contains("这一整页都应该保留"))
    }

    func testDropsTrailingNavLabels() {
        let html = """
        <html><body><article class="article-body">
          <p>正文结尾是一句完整的话。</p>
          <p>间隔重复</p><p>概念</p><p>学习软件</p><p>践行和研究者</p>
        </article></body></html>
        """
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertTrue(body.contains("正文结尾是一句完整的话。"))
        XCTAssertFalse(body.contains("学习软件"))
        XCTAssertFalse(body.contains("践行和研究者"))
    }

    func testKeepsShortClosingSentence() {
        let html = "<html><body><article class=\"article-body\"><p>正文。</p><p>谢谢阅读！</p></article></body></html>"
        let body = ClipExtractor.text(fromHTML: html)
        XCTAssertTrue(body.contains("谢谢阅读！"))
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
