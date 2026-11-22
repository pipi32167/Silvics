# Silvics

单人用的 macOS 原生笔记应用。笔记正文是 Markdown 纯文本，写概念名时自动找出已有笔记并提示建立连接。

名字取自 **silvics**（林业术语，研究林木如何生长），对应「笔记需要培育，不需要归档」。

![主界面](docs/images/main-window.png)

## 核心设计

**标题即接口。** 标题写成完整断言句（`稀疏重复优于集中突击`），才能在别的笔记正文里当作自然语言句子使用。机器能定位它，连接才能自动成立。这是自动连接的前提，也是新建笔记时强制校验标题的原因。

**连接分四层，硬软隔离。**

| 层 | 机制 | 可靠性 | 改正文 | 进主图 |
| --- | --- | --- | --- | --- |
| L1 | `[[ ]]` 显式引用 | 确定 | 是（用户手动） | 是 |
| L2 | 未链接提及（字符串匹配已有标题） | 确定 | 一键转 | 否 |
| L3 | 概念抽取 → 建议新建 | 中 | 永不 | 否 |
| L4 | embedding 语义近邻 | 低 | 永不 | 否 |

L3 与 L4 永不改写用户正文。自动改一次错，整个连接层的信任归零。

**正文是唯一真相。** 连接表、提及表、向量表都是索引，任何时候都能从正文全量重建。这消除「图里有边、正文里没有」的漂移。

![引用补全](docs/images/completion.png)

**L2 已落地：未链接提及。** 正文里写到已有标题（或别名）时，该片段带点状下划线，右侧面板列出可一键转换。批量整理分三步：选择 → 看 diff → 转换，转换可撤销。

| 动作 | 快捷键 |
| --- | --- |
| 把光标所在提及转成引用 | `⌘⇧K` |
| 整理未链接提及 | `⌘⇧M` |
| 重命名笔记（连带改写正文引用） | `⌘⇧R` |
| 编辑别名 | `⌘⇧A` |
| 立即保存 | `⌘S` |

## 技术栈

| 层 | 选择 | 理由 |
| --- | --- | --- |
| 编辑区 | 原生 `NSTextView`（TextKit 2） | WKWebView 的中文输入有已知缺陷，且拿不到系统文本服务 |
| 存储 | GRDB 7（SQLite WAL） | SwiftData 无全文搜索 |
| 全文搜索 | FTS5 `trigram` 分词器 | 中文子串可搜 |
| Markdown 解析 | `swift-markdown` | 只用于非引用语法与导出 |
| 引用解析 | 自写 `WikiScanner` | 编辑器要字符区间，不要 AST |
| 工程 | xcodegen | `project.yml` 是唯一真相 |

## 构建

需要 Xcode 26+、macOS 14+、`xcodegen`。

```bash
# 本机 Xcode 不在默认位置时必须设
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodegen generate
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO build
```

产物在 `.build/Build/Products/Debug/Silvics.app`。

SPM 拉依赖时如果卡在 `Fetching from https://github.com/...`，说明到 GitHub 的 HTTPS 不通，挂代理再跑：

```bash
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 ALL_PROXY=http://127.0.0.1:7890
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://127.0.0.1:7890
```

跑测试：

```bash
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO test > /tmp/silvics-test.log 2>&1
grep -E "TEST (SUCCEEDED|FAILED)" /tmp/silvics-test.log
```

## 文档

- [docs/设计文档.md](docs/设计文档.md)：完整设计，含本机实测数据（UTF-8 字节偏移坑、Aho–Corasick 对比、`NLEmbedding` 中文不可用）
- [docs/HANDOFF.md](docs/HANDOFF.md)：进度、已知缺陷、下一步

## 进度

P1 完成：写作、`[[` 补全、引用与悬空样式、反向链接面板、自动保存、全文搜索。

P2 完成：Aho–Corasick 提及扫描（Release 实测 0.035 ms / 1000 标题）、未链接提及面板、批量转换与 diff 预览、撤销、别名、改名时批量重写正文引用。

P3 未开始：`⌘P` Quick Open、孤儿笔记视图、标签、搜索实测。
