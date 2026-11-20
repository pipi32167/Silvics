# Silvics 交接文档

写给接手这个项目的下一个 agent。读完这一份就能继续干活。

- 交接时间：2026-11-20
- 项目路径：`/Volumes/WD_BLACK_2T/projects/silvics`
- 当前阶段：P1 完成，P2 未开始
- 设计文档：[设计文档.md](设计文档.md)（先读它，共 13 章）

---

## 1. 一句话说明

Silvics 是一个单人用的 macOS 原生笔记应用。笔记正文是 Markdown 纯文本。用户在正文里写概念名时，应用自动找出这个概念的已有笔记并提示建立连接。

核心不是「能写笔记」。核心是**概念引用自动成立**。

## 2. 环境

| 项 | 值 |
| --- | --- |
| macOS | 26.5.2 |
| Xcode | 26.5 |
| Swift | 6.3.2 |
| 工程生成 | `xcodegen` 2.x（已装） |
| 依赖 | GRDB.swift 7.12+、swift-markdown 0.9+，均由 SPM 拉取 |
| 沙盒 | 关闭，必须关闭 |

## 3. 目录

```text
silvics/
├── project.yml                 ← 工程定义。改配置改这里，不要改 .xcodeproj
├── Silvics.xcodeproj/          ← xcodegen 生成物，不入库
├── Support/Info.plist          ← xcodegen 生成物，不入库
├── Sources/Silvics/
│   ├── SilvicsApp.swift        入口、菜单、AppDelegate（退出前 flush）
│   ├── App/
│   │   ├── AppState.swift      单一状态源，@MainActor
│   │   └── DemoSeeder.swift    仅 DEBUG，SILVICS_SEED=1 时灌 20 条演示笔记
│   ├── Core/
│   │   ├── Models.swift        Note / NoteLink / NoteMention / 视图模型 / 标题校验
│   │   ├── AppDatabase.swift   GRDB 建库与迁移 v1
│   │   ├── NoteStore.swift     GRDBNoteRepository：读写、重算索引、搜索
│   │   └── DebugLog.swift      写 /tmp/silvics-debug.log，仅 DEBUG
│   ├── EditorKit/              不导入 SwiftUI / AppKit UI，可单测
│   │   ├── WikiScanner.swift   `[[ ]]` 扫描器（跳过代码块、行内代码、URL）
│   │   ├── MarkdownStyler.swift swift-markdown AST → NSRange（UTF-8 字节映射）
│   │   └── Theme.swift         字体、颜色、段落样式
│   └── UI/
│       ├── RootView.swift      三栏 NavigationSplitView + 状态条
│       ├── SidebarView.swift   搜索、笔记列表、孤儿计数
│       ├── EditorView.swift    NSTextView 桥、样式应用、补全、⌘ 点击引用
│       ├── CompletionPanel.swift  `[[` 补全浮层（无标题 NSPanel）
│       ├── ContextPanelView.swift 反向链接 / 出链 / 悬空引用
│       └── NewNoteSheet.swift  新建笔记 + 标题校验 + 查重
├── Tests/SilvicsTests/
│   └── EditorKitTests.swift    25 个单测
└── docs/
    ├── 设计文档.md
    └── HANDOFF.md              ← 本文件
```

代码量：约 3400 行 Swift，含测试。

## 4. P1 已完成

按验收标准逐条对照。

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| Xcode 项目 | 完成 | `project.yml` → `xcodegen generate` |
| GRDB 建库与迁移 v1 | 完成 | 8 张表，含 FTS5 trigram |
| 三栏布局 | 完成 | 截图 05 |
| NSTextView 编辑区 | 完成 | 截图 02、05、06 |
| `[[` 补全浮层 | 完成 | 截图 06 |
| 引用与悬空样式 | 完成 | 截图 05（绿色实线）/ 悬空为灰色虚线 |
| 反向链接面板 | 完成 | 截图 05（4 条，带上下文片段） |
| 自动保存（500 ms 防抖 + 失焦/退出 flush） | 完成 | 切换笔记后重开数据仍在 |
| 连写多条互相引用的笔记不丢数据 | 完成 | 演示数据 20 条 / 31 条边，重启后完整 |
| 单测 | 25 项全过 | `xcodebuild test` |

额外做了设计文档里没写但必须有的：标题校验（拒日期、拒官僚前缀、拒 `[ ] ( )`）、新建时查重（标题二元组 Jaccard 相似度前 3）、悬空引用一键新建、索引重建菜单项、状态条。

## 5. 怎么跑

```bash
cd /Volumes/WD_BLACK_2T/projects/silvics
xcodegen generate                      # 新增源文件后必须重跑
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO build
```

取产物路径。这台机器的 Xcode 全局设了 `IDEBuildLocationStyle=Custom`，`-derivedDataPath .build` **不决定**产物位置：

```bash
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -showBuildSettings 2>/dev/null | grep -E "BUILT_PRODUCTS_DIR"
# 实测为 /Volumes/WD_BLACK_2T/tmp/Xcode/Build/Products/Debug
```

带演示数据启动：

```bash
rm -rf "$HOME/Library/Application Support/Silvics"
open -a "<BUILT_PRODUCTS_DIR>/Silvics.app" --env SILVICS_SEED=1
```

同一台机器上所有 Xcode 构建共用 `/Volumes/WD_BLACK_2T/tmp/Xcode/Build/Intermediates.noindex`。
原仓库与克隆同时构建会报 `database is locked`。跑之前先 `pkill -f xcodebuild`。

跑测试（输出必须重定向，否则被系统日志淹没）：

```bash
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO test > /tmp/t.log 2>&1
grep -E "Test Case.*(passed|failed)|TEST (SUCCEEDED|FAILED)" /tmp/t.log
```

数据库位置：`~/Library/Application Support/Silvics/silvics.sqlite`（WAL 模式）。

### 交接已验证

2026-11-20 从一个空目录干净克隆 `https://github.com/pipi32167/Silvics.git` 后：

```text
xcodegen generate          → 生成工程
xcodebuild ... build       → BUILD SUCCEEDED
xcodebuild ... test        → 25 tests, 0 failures, TEST SUCCEEDED
```

也就是说下一任 agent 不需要本机的任何残留物就能起来。

## 6. 截图与自动化验收

- 单窗口截图：`screencapture -x -o -l<windowID> out.png`
- **取窗口 ID**：编译 `/tmp/wininfo.swift`（`CGWindowListCopyWindowInfo`），别用 AppleScript，拿不到 CGWindowID。
- **坑**：`-l` 只抓该窗口，`[[` 补全浮层是独立 `NSPanel`，**不在截图里**。抓浮层必须 `screencapture -x` 全屏再裁。窗口在点坐标下的位置同样从 `wininfo` 取，截图是 2 倍图。
- **坑**：自动化的前提是 Silvics 真的在最前。`osascript ... set frontmost` 会被别的 App 抢。每次动作前用 `tell application "System Events" to get name of first process whose frontmost is true` 确认，必要时用 `open -a <app>` + `tell application "Silvics" to activate`。
- 已产出截图在 `/tmp/reports/silvics-p1/artifacts/raw/`：`02-main-fixed.png`、`05-note-dense-links.png`、`06-completion.png`。`01-main.png`、`03-backlinks.png`、`04-completion.png` 是过程图，含已修复的缺陷，不要当验收证据。
- **未自动验证**：真实中文输入法（IME）组合期行为。这需要人工在系统拼音输入法下敲一段中文，确认候选窗位置、无丢字、无重排。P1 的验收标准里有这一项，目前只有「粘贴中文」这一路测过，**必须人工补测**。

## 7. 必须知道的坑（已经踩过，别再踩）

1. **`swift-markdown` 的 `SourceLocation.column` 是 UTF-8 字节。** 不是字符，不是 UTF-16。按字符映射会让整篇中文的样式全部错位。已有回归测试 `testStrongRangeUsesUTF8Columns` 守着。
2. **新增源文件后必须重跑 `xcodegen generate`。** `project.yml` 里是按目录声明 sources，工程在生成时固定文件列表。漏跑的表现是「文件明明存在，编译却说找不到符号」。踩过一次。
3. **先写的 `[[尚未存在的概念]]` 不会自动接上。** 目标笔记后建出来时必须重算。`NoteStore.resolveAllLinks` 就是干这个的，每次 `save` 都调。漏了的表现是「标题明明在库里，悬空引用却一堆」。踩过一次，已有两个测试守着。
4. **切换笔记会复用/重建 `NoteEditorView`，旧的 `NSPanel` 必须显式收掉。** 漏了会留一个孤立空面板。已在 `dismantleNSView` 与 `deinit` 里处理。
5. **`isRichText` 必须是 `true`。** 改成 `false` 后 `NSTextView` 会在编辑时用统一字体覆盖整段，我们程序化应用的属性全被清掉。粘贴降级为纯文本靠 `importsGraphics = false` 与关闭自动替换实现，不靠这个开关。
6. **`App Sandbox` 必须关。** 开了连不上 `127.0.0.1` 的 Ollama。
7. **`link` 表的列名不要叫 `offset`**，SQLite 保留字。已改名 `location`。
8. **`NLEmbedding` 的中文句向量不可用。** 实测相关 0.9454 / 无关 0.9405，差距 0.005。L4 必须走云端 BYOK。数据在设计文档 8.5。
9. **不要给 `swift-markdown` 加 `[[ ]]` 自定义语法。** 编辑器要的是字符区间不是 AST，用自写的 `WikiScanner`。
10. **`xcodebuild` 并发会锁 build.db。** 报 `database is locked` 时先 `pkill -f xcodebuild`，或先杀掉在跑的 App。

## 8. 已知缺陷与未做

| 项 | 说明 |
| --- | --- |
| 中文输入法未实测 | 见第 6 节。P1 验收缺口，优先级最高 |
| 补全面板位置 | 用 `layoutManager` 算光标矩形。TextKit 2 下这是兼容层，多行折行处位置可能偏。需实测校正 |
| 补全不响应鼠标滚轮 | 列表超过 6 项时靠 ↑↓ 滚动 |
| 无 `⌘P` Quick Open | 设计文档 5.2 有，P3 做 |
| 搜索只到 FTS5 | 已实现但有 bug：`completionItems` 里 `titleKey LIKE` 未转义 `%` 与 `_` |
| 无撤销回归测试 | `undoManager.disableUndoRegistration` 包了属性应用，但没测过连续撤销 |
| 属性应用是全量 | 每次输入全量 `setAttributes` + 全量分析。800 字实测 0.25 ms 解析，可接受；超过 5000 字的笔记会开始掉帧，设计文档 7.4 写了要改段落级增量 |
| `DebugLog` 留在 DEBUG 构建里 | 写 `/tmp/silvics-debug.log`。Release 不编译 |
| `DemoSeeder` 留在 DEBUG 构建里 | 仅在 `SILVICS_SEEED=1` 且库为空时生效 |

## 9. 下一步：P2

按设计文档第 9 章。P2 的验收标准：1000 条测试数据下，单篇提及扫描不超过 1 ms（设计文档实测 0.099 ms）。

任务清单，按顺序做：

1. **Aho–Corasick 提及扫描器**。新建 `Sources/Silvics/EditorKit/MentionScanner.swift`。转移表键用 `[UInt32: Int]`，中文标量直接作键。`out` 数组沿 fail 链合并保证重叠命中。返回 `(patternIndex, endOffset)`，用 `endOffset - title.count` 反推起点。
2. **过滤三类区间**：代码块、行内代码、已是引用的区间。区间由 `MarkdownStyler` 与 `WikiScanner` 的现有输出提供。
3. **中文三条门槛**：匹配片段长度不小于 4 汉字、不在停用词表、单篇同目标上限 20 次。
4. **写入 `mention` 表**。表已建好（`AppDatabase` 迁移 v1），`NoteMention` 模型已有。
5. **侧栏「未链接提及」区**。`ContextPanelView` 加一段，仿 `backlinks` 的写法。
6. **批量转换 + diff 预览**。转换是不可逆文本改动，必须先给 diff 再让用户确认。
7. **别名（alias）**。表已建好，`NoteStore.reindex` 已在读 `alias` 表解析引用，但没有写入路径。需要 UI 与 CRUD。
8. **标题改名时批量重写正文引用**。`resolveAllLinks` 已能退回悬空，但没做「把旧标题改写成新标题」。
9. **补测中文输入法**（第 8 节第一项）。

P3 及之后见设计文档第 9 章。

## 10. 不要做的事

- 不要引入第三方 Markdown 编辑器库。Swift 侧没有可用的，STTextView 是 GPLv3。
- 不要在 P1/P2 阶段做「隐藏 Markdown 语法标记」。设计文档 7.4 的方案 B，风险见第 6 章。
- 不要让 L3/L4 改写用户正文。设计文档 3.1 的铁律。
- 不要把连接表当真源。真源永远是 `note.body`，索引随时可重建。
- 不要改 `~/.pi/agent/AGENTS.md`。项目规则只写本仓库的 `AGENTS.md`。

## 11. 历史决策记录

| 决策 | 结论 | 理由位置 |
| --- | --- | --- |
| Web 还是原生 | 原生 Swift | 设计文档第 6 章，含 CodeMirror 中文 IME 缺陷证据 |
| 应用名 | Silvics | 设计文档 11.1 |
| 编辑器 | 原生 NSTextView，不用 STTextView | 设计文档 7.3 |
| 存储 | GRDB + SQLite，不用 SwiftData | 设计文档 7.1（SwiftData 无 FTS） |
| 引用解析 | 自写扫描器，不用 swift-markdown | 设计文档 7.4 |
| 提及扫描 | Aho–Corasick，不用朴素匹配 | 设计文档 8.4（朴素 214 ms，AC 0.099 ms） |
| L4 向量 | 云端 BYOK，不用 NLEmbedding | 设计文档 8.5（实测差距 0.005） |
| 语法渲染 | 保留标记 + 样式化，不隐藏 | 设计文档 7.4 方案 A |
