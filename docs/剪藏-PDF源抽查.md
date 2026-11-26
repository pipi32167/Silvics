# 剪藏：常见论文库的 PDF 路径抽查

2026-11-26，为 issue #30 / #43 做的抽查。目的两个：**链接能不能直接抓**，**抓到的 PDF 抽文字干不干净**。

工具：`curl` 带 Safari UA 直连；抽文字用 PDFKit（与应用一致）与 PyMuPDF（对照）。

## 一、链接层：多数论文库抓不到 PDF

| 来源 | 返回 | 结果 |
| --- | --- | --- |
| arXiv（`/pdf/...`） | 200 application/pdf | 能直连 |
| ACL Anthology | 200 application/pdf | 能直连 |
| NBER working paper | 200 application/pdf | 能直连 |
| Nature Communications | 200 application/pdf | 能直连 |
| PLOS ONE | 200 application/pdf | 能直连 |
| SpringerOpen（EPJ 系） | 200 application/pdf | 能直连 |
| MDPI | 403 text/html | 拒绝 |
| Springer Link（`content/pdf/...`） | 200 text/html | 拿到的是页面，不是 PDF |
| Wiley | 403 text/html | 拒绝 |
| PNAS | 403 text/html | 拒绝 |
| Science | 403 text/html | 拒绝 |
| IEEE Xplore | 202 text/html（空） | JS 挑战页 |
| ScienceDirect | 403 text/html | 拒绝 |
| bioRxiv | 429 | 限流 |
| 万方 | 200 text/html | 页面要 JS 与登录 |
| CNKI | 需登录 | 抓不到 |

结论：**用户贴论文库链接时，多数情况拿不到 PDF**，应提示「先下载 PDF 再拖进来」。能直连的是 arXiv 系与少数开放仓库。

## 二、抽文字：约五分之一的 PDF 会丢空格

同一批 PDF 用 PDFKit 与 PyMuPDF 各抽一次，比拉丁词数。词数骤降＝空格被吞（`Provingand ImprovingthePlatonic`）。

| PDF | 页 | PDFKit 词数 | PyMuPDF 词数 | 比值 | 判定 |
| --- | --- | --- | --- | --- | --- |
| arXiv 1706.03762（Attention） | 15 | 4326 | 4320 | 1.00 | 正常 |
| arXiv 2305.18290（DPO） | 27 | 9903 | 9962 | 0.99 | 正常 |
| arXiv hep-th/9201001（1992） | 47 | 5404 | 5273 | 1.02 | 正常 |
| ACL Anthology 2024.acl-long.1 | 17 | 8048 | 8054 | 1.00 | 正常 |
| Nature Communications | 12 | 6183 | 6175 | 1.00 | 正常 |
| NBER w31234 | 25 | 8229 | 8229 | 1.00 | 正常 |
| PLOS ONE | 11 | 3715 | 3715 | 1.00 | 正常 |
| SpringerOpen EPJ（硼中子俘获） | 15 | 1962 | 5076 | **0.39** | 丢空格 |
| alphaXiv 2610.39302（PRH-JEPA） | 37 | 12154 | 18792 | **0.65** | 丢空格 |

9 份里 2 份出问题（22%）。

## 三、为什么会丢，以及为什么救不回来

- 这两份 PDF 的文字层里**有真的空格字形**（PyMuPDF 的 `rawdict` 能看到 `' '`，宽度 4.30 / 2.99 pt）。
- PDFKit 的 `page.string`、`attributedString`、`selection(for:).string` 全部把它们吞掉；`selectionForWord(at:)` 还把它当**一个词**（`Provingand`）。
- `page.characterBounds(at:)` 里相邻字形的 `maxX` 与下一个 `minX` 相等，**没有几何间隙可用**，所以「量间距补空格」这条路在 PDFKit 里走不通。

结论：要根治只能换抽取层（自解析 content stream，或引入 PDFium / poppler 类），或在应用里做词边界启发式（有误切风险，需可关）。

## 四、复现

```bash
curl -sL -o /tmp/a.pdf "https://pdfs.assets.alphaxiv.org/2610.39302v1.pdf"
# 应用侧
SILVICS_SHOW=clip-pdf SILVICS_CLIP_FILE=/tmp/a.pdf SILVICS_VAULT=/tmp/v SILVICS_DB=/tmp/d.sqlite \
  .build/Build/Products/Debug/Silvics.app/Contents/MacOS/Silvics
# 对照（需要 PyMuPDF）
python3 -c "import pymupdf; d=pymupdf.open('/tmp/a.pdf'); print(d[0].get_text('text')[:200])"
```
