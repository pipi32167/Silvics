# silvics · feat-clip-pdf 验收报告

## 元信息

| 项 | 值 |
| --- | --- |
| commit | 888f784 |
| 验收时间 | 2026-11-26 11:22 CST |
| 环境 | macOS 14+，Debug 构建，离屏渲染 2x（验收时机器锁屏，窗口通道出不了图） |
| 数据 | 自造 PDF 夹具：中英两页件、61 页长文档、无文字层扫描件、带密码加密件；本地 HTTP server 8799 提供 PDF 与网页 |
| 缓存版本 | 待确认 |
| 验收人 | agent |

## 结论

通过 8 项，不通过 0 项，待确认 0 项，未覆盖 3 项。

## 覆盖用例

| # | 用例 | 判据 | 结果 | 证据 |
| --- | --- | --- | --- | --- |
| 01 | 电子版 PDF 导入后的预览 | 标题取文档属性标题；字数等于抽取结果；截图里无乱码 | 通过 | `artifacts/01-pdf-preview-zh-en.png` |
| 02 | 超过 60 页按页截断 | 提示写明文件大小、总页数、实际取了几页；字数只算前 60 页 | 通过 | `artifacts/02-pdf-truncated.png` |
| 03 | 截断提示 4x 细节 | 「这份 PDF 0.1 MB、共 61 页，只取了前 60 页。」可读无截断 | 通过 | `artifacts/03-truncate-warning-4x.png` |
| 04 | 扫描件与加密件的兜底 | 给明确原因；自动切到粘贴框；标题预填文件名；不写空剪藏 | 通过 | `artifacts/04-pdf-reject-fallback.png` |
| 05 | 网址入口：PDF 与网页走同一条抓取链 | 同一面板两种结果都对；网页剪藏行为未变 | 通过 | `artifacts/05-url-pdf-and-web.png` |
| 06 | 存进库后的阅读效果 | 标点正确；段落完整；页与页之间空行；无乱码 | 通过 | `artifacts/06-reader-zh-en.png` |
| 07 | 正文 4x 细节 | 「，」「。」是全角；「工具」「长文」已从康熙部首折回；段内折行已接回 | 通过 | `artifacts/07-zh-body-4x.png` |
| 08 | 剪藏列表与计数 | 列表两行；未读 1、全部 2、待整理 2 | 通过 | `artifacts/08-clip-list.png` |

## 偏差清单

| 区域 | 设计稿值 | 实现值 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| 页数上限与体积上限 | issue #30 写「沿用 5 MB 上限，超过只取前 N 页」 | 页数 60 页即截断（与体积无关）；本地 100 MB、网址下载 20 MB 才是硬拒 | 已修复 | `artifacts/02-pdf-truncated.png` |

## 未覆盖

| 用例 | 原因 |
| --- | --- |
| 拖入 PDF（文件 / 网址 / 文本三种拖法） | 拖拽需要真实指针与窗口，锁屏下无法执行；实现走的是与选择文件相同的 ingestFile / ingestURL 路径 |
| 深色模式与多语言 | 本次改动只有面板里的提示文案与既有控件，未新增外观分支；深色下的 PDF 文案沿用同一套 Label |
| 100 MB 本地上限与 OCR | 100 MB 上限有单测覆盖但没造这么大的夹具；OCR 不在本期范围 |

## 复现命令

```bash
swiftc -O /tmp/mkpdf.swift -o /tmp/mkpdf && /tmp/mkpdf   # 造 PDF 夹具到 /tmp/pdf-fix
cd /tmp/pdf-fix && python3 -m http.server 8799 --bind 127.0.0.1   # 供「网址直连 PDF」用例
SILVICS_OFFSCREEN_SHEET=new-clip SILVICS_CLIP_FILE=/tmp/pdf-fix/zh.pdf SILVICS_OFFSCREEN=/tmp/pdf-shots/01.png SILVICS_VAULT=/tmp/v SILVICS_DB=/tmp/d.sqlite .build/Build/Products/Debug/Silvics.app/Contents/MacOS/Silvics   # 面板预览态
SILVICS_SHOW=clip-pdf SILVICS_CLIP_FILE=/tmp/pdf-fix/zh.pdf SILVICS_OFFSCREEN=/tmp/pdf-shots/07.png SILVICS_VAULT=/tmp/v SILVICS_DB=/tmp/d.sqlite .build/Build/Products/Debug/Silvics.app/Contents/MacOS/Silvics   # 导入并读
```

## 证据图

### 01 电子版 PDF 导入后的预览

<img src="artifacts/01-pdf-preview-zh-en.png" alt="01-电子版-PDF-导入后的预览" width="640">

[原图](artifacts/01-pdf-preview-zh-en.png) · 通过 · 判据 标题取文档属性标题；字数等于抽取结果；截图里无乱码

中英各一份，都走到预览态

### 02 超过 60 页按页截断

<img src="artifacts/02-pdf-truncated.png" alt="02-超过-60-页按页截断" width="628">

[原图](artifacts/02-pdf-truncated.png) · 通过 · 判据 提示写明文件大小、总页数、实际取了几页；字数只算前 60 页

状态矩阵 61 页长文档

### 03 截断提示 4x 细节

<img src="artifacts/03-truncate-warning-4x.png" alt="03-截断提示-4x-细节" width="640">

[原图](artifacts/03-truncate-warning-4x.png) · 通过 · 判据 「这份 PDF 0.1 MB、共 61 页，只取了前 60 页。」可读无截断

细节放大 1 块 x2

### 04 扫描件与加密件的兜底

<img src="artifacts/04-pdf-reject-fallback.png" alt="04-扫描件与加密件的兜底" width="720">

[原图](artifacts/04-pdf-reject-fallback.png) · 通过 · 判据 给明确原因；自动切到粘贴框；标题预填文件名；不写空剪藏

状态矩阵 扫描件（无文字层） / 加密 PDF

### 05 网址入口：PDF 与网页走同一条抓取链

<img src="artifacts/05-url-pdf-and-web.png" alt="05-网址入口PDF-与网页走同一条抓取链" width="640">

[原图](artifacts/05-url-pdf-and-web.png) · 通过 · 判据 同一面板两种结果都对；网页剪藏行为未变

本地 HTTP server 8799 提供 zh.pdf 与 post.html

### 06 存进库后的阅读效果

<img src="artifacts/06-reader-zh-en.png" alt="06-存进库后的阅读效果" width="720">

[原图](artifacts/06-reader-zh-en.png) · 通过 · 判据 标点正确；段落完整；页与页之间空行；无乱码

状态矩阵 库里读中文 PDF 剪藏 / 库里读英文 PDF 剪藏

### 07 正文 4x 细节

<img src="artifacts/07-zh-body-4x.png" alt="07-正文-4x-细节" width="640">

[原图](artifacts/07-zh-body-4x.png) · 通过 · 判据 「，」「。」是全角；「工具」「长文」已从康熙部首折回；段内折行已接回

细节放大 1 块 x2

### 08 剪藏列表与计数

<img src="artifacts/08-clip-list.png" alt="08-剪藏列表与计数" width="640">

[原图](artifacts/08-clip-list.png) · 通过 · 判据 列表两行；未读 1、全部 2、待整理 2

状态矩阵 两篇 PDF 剪藏

## 截图清单

| 文件 | 说明 | 差异 |
| --- | --- | --- |
| `artifacts/01-pdf-preview-zh-en.png` | 中英各一份，都走到预览态 | — |
| `artifacts/02-pdf-truncated.png` | 状态矩阵 61 页长文档 | — |
| `artifacts/03-truncate-warning-4x.png` | 细节放大 1 块 x2 | — |
| `artifacts/04-pdf-reject-fallback.png` | 状态矩阵 扫描件（无文字层） / 加密 PDF | — |
| `artifacts/05-url-pdf-and-web.png` | 本地 HTTP server 8799 提供 zh.pdf 与 post.html | — |
| `artifacts/06-reader-zh-en.png` | 状态矩阵 库里读中文 PDF 剪藏 / 库里读英文 PDF 剪藏 | — |
| `artifacts/07-zh-body-4x.png` | 细节放大 1 块 x2 | — |
| `artifacts/08-clip-list.png` | 状态矩阵 两篇 PDF 剪藏 | — |
