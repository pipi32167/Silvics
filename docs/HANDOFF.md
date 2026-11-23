# Silvics 交接文档

写给接手这个项目的下一个 agent。读完这一份就能继续干活。

- 交接时间：2026-11-22
- 项目路径：`~/work/dev/Silvics`
- 当前阶段：P1、P2、P3 完成，P4 未开始
- 设计文档：[设计文档.md](设计文档.md)（先读它，共 13 章）

---

## 1. 一句话说明

Silvics 是一个单人用的 macOS 原生笔记应用。笔记正文是 Markdown 纯文本。用户在正文里写概念名时，应用自动找出这个概念的已有笔记并提示建立连接。

核心不是「能写笔记」。核心是**概念引用自动成立**。

## 2. 环境

| 项 | 值 |
| --- | --- |
| macOS | 27.0.1 |
| Xcode | 27.2（`/Applications/Xcode.app`） |
| Swift | 6.4 |
| 工程生成 | `xcodegen` 2.48（`brew install xcodegen`，已在 PATH） |
| 依赖 | GRDB.swift 7.12+、swift-markdown 0.9+，由 SPM 拉取 |
| 沙盒 | 关闭，必须关闭 |

### 本机环境与上一台机器不同，必须知道

1. **`xcodebuild` 默认指向 CommandLineTools，直接跑会报错。** 每次构建前设 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
2. **`github.com` 直连不通。** SPM 拉包会卡在 `Fetching from https://...`。构建时挂本地代理：

   ```bash
   export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 ALL_PROXY=http://127.0.0.1:7890
   export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://127.0.0.1:7890
   ```

   依赖拉好之后，后续构建不需要代理。
3. **`api.github.com`、`codeload.github.com` 直连可用，SSH 推送也可用。** 只有 `github.com` 的 HTTPS 与 git-over-https 不通。
4. **上一份文档记的「构建位置陷阱」在这台机器上不存在。** `defaults read com.apple.dt.Xcode IDEBuildLocationStyle` 无值，`-derivedDataPath .build` 正常生效，产物在 `.build/Build/Products/Debug/Silvics.app`。

## 3. 目录

```text
Silvics/
├── project.yml                 ← 工程定义。改配置改这里，不要改 .xcodeproj
├── Silvics.xcodeproj/          ← xcodegen 生成物，不入库
├── Support/Info.plist          ← xcodegen 生成物，不入库
├── Sources/Silvics/
│   ├── SilvicsApp.swift        入口、菜单、AppDelegate（退出前 flush）
│   ├── App/
│   │   ├── AppState.swift      单一状态源，@MainActor
│   │   ├── DebugCapture.swift  仅 DEBUG：窗口自绘成 PNG，取证用
│   │   └── DemoSeeder.swift    仅 DEBUG，SILVICS_SEED=1 时灌 20 条演示笔记
│   ├── Core/
│   │   ├── Models.swift        Note / NoteLink / NoteMention / 视图模型 / 标题校验
│   │   ├── AppDatabase.swift   GRDB 建库与迁移 v1
│   │   ├── NoteStore.swift     读写、重算索引、搜索、引用解析
│   │   ├── MentionIndex.swift  提及索引：自动机缓存、写入、查询、批量转换
│   │   ├── NoteStoreMentions.swift  提及的仓库方法（转换 / 撤销 / 预览）
│   │   ├── NoteStoreAliases.swift   别名 CRUD、改名批量重写正文
│   │   ├── NoteStoreLists.swift     标签筛选、孤儿、Quick Open 排序
│   │   ├── TagIndex.swift      标签索引：从正文扫 #标签
│   │   └── DebugLog.swift      写 /tmp/silvics-debug.log，仅 DEBUG
│   ├── EditorKit/              不导入 SwiftUI / AppKit UI，可单测
│   │   ├── WikiScanner.swift   `[[ ]]` 扫描器（跳过代码块、行内代码、URL）
│   │   ├── MentionScanner.swift  Aho–Corasick 提及扫描 + 归一化 + 门槛
│   │   ├── TagScanner.swift    `#标签` 扫描（跳过标题、代码、引用、URL）
│   │   ├── StopWords.swift     提及停用词表
│   │   ├── MarkdownStyler.swift swift-markdown AST → NSRange（UTF-8 字节映射）
│   │   ├── LineDiff.swift      行级 diff，批量转换预览用
│   │   └── Theme.swift         字体、颜色、段落样式
│   └── UI/
│       ├── RootView.swift      三栏 NavigationSplitView + 状态条
│       ├── SidebarView.swift   搜索、笔记列表
│       ├── EditorView.swift    NSTextView 桥、样式、补全、提及下划线、⌘⇧K
│       ├── CompletionPanel.swift  `[[` 补全浮层（无标题 NSPanel）
│       ├── ContextPanelView.swift 反向链接 / 提及 / 出链 / 悬空
│       ├── NewNoteSheet.swift  新建笔记 + 标题校验 + 查重
│       ├── MentionSheet.swift  未链接提及批量整理（选择 → diff → 转换）
│       ├── AliasSheet.swift    别名增删
│       └── RenameSheet.swift   改名 + 影响预览
├── Tests/SilvicsTests/
│   ├── EditorKitTests.swift    27 个 P1 单测
│   ├── MentionTests.swift      扫描器 / 归一化 / 门槛 / 性能
│   ├── MentionDatabaseTests.swift  提及、别名、改名、转义
│   ├── TagAndListTests.swift   标签、孤儿、Quick Open、搜索性能
│   └── LineDiffTests.swift     diff
└── docs/
    ├── 设计文档.md
    └── HANDOFF.md              ← 本文件
```

代码量：约 7000 行 Swift，含测试。

## 4. 已完成

### P1

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| Xcode 项目 | 完成 | `project.yml` → `xcodegen generate` |
| GRDB 建库与迁移 v1 | 完成 | 8 张表，含 FTS5 trigram |
| 三栏布局 | 完成 | P1 截图 |
| NSTextView 编辑区 | 完成 | P1 截图 |
| `[[` 补全浮层 | 完成 | P1 截图 |
| 引用与悬空样式 | 完成 | 绿色实线 / 灰色虚线 |
| 反向链接面板 | 完成 | 带上下文片段 |
| 自动保存（500 ms 防抖 + 失焦/退出 flush） | 完成 | 切换笔记后重开数据仍在 |
| 单测 | 完成 | 见第 5 节 |

### P2

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| Aho–Corasick 提及扫描 | 完成 | Release 实测 1000 标题 / 805 字正文 **0.035 ms**（预算 1 ms） |
| 排除代码块、行内代码、已有引用 | 完成 | `testCodeBlockMentionIgnored`、`testExistingWikiLinkNotAMention` |
| 中文三条门槛 | 完成 | 长度 ≥4 汉字、停用词、单篇同目标上限 20 |
| 写入 `mention` 表 | 完成 | 真机验证：演示数据 20 条笔记产出 2 条提及，目标与偏移正确 |
| 编辑区点状下划线 + `⌘⇧K` 转换 | 完成 | 转换走 `shouldChangeText`，可 `⌘Z` |
| 侧栏「未链接提及」区 | 完成 | 右侧面板新增一段，带转换 / 忽略 / 整理 |
| 批量转换 + diff 预览 | 完成 | `MentionSheet`：选择 → 行级 diff → 转换 |
| 批量转换可撤销 | 完成 | 菜单「撤销上次批量转换」，或面板里的按钮 |
| 别名 | 完成 | 表已有，新增 CRUD、UI、提及匹配、`[[别名]]` 解析 |
| 改名时批量重写正文引用 | 完成 | 先给影响预览，改后旧标题自动进别名 |
| 单测 | 完成 | 99 项全过 |

额外修掉：`completionItems` 与短查询搜索里 `LIKE` 未转义 `%` / `_` 的 bug。

### P3

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| `⌘P` Quick Open | 完成 | `QuickOpenSheet`，前缀 → 包含 → 二元组相似度排序，空查询给最近更新 |
| 孤儿笔记视图 | 完成 | 侧栏「孤儿笔记」范围 + `⌘⇧O`，演示数据 21 条里有 1 条 |
| 标签 | 完成 | `TagScanner` 扫 `#标签`（跳过 ATX 标题、代码块、行内代码、`[[ ]]`、URL） |
| 标签筛选 | 完成 | 侧栏标签列表按使用次数排序，点击切范围 |
| 搜索摘要 | 完成 | 以命中处为中心取片段，前后加省略号 |
| 搜索性能 | 完成 | 1000 条笔记，Debug 实测 **4.7 ms**（验收线 100 ms） |
| 单测 | 完成 | 99 项全过 |

## 5. 怎么跑

```bash
cd ~/work/dev/Silvics
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # 必须
xcodegen generate                                                  # 新增源文件后必须重跑
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO build
```

产物：`.build/Build/Products/Debug/Silvics.app`。

带演示数据启动：

```bash
rm -rf "$HOME/Library/Application Support/Silvics"
open -a .build/Build/Products/Debug/Silvics.app --env SILVICS_SEED=1
```

跑测试（输出必须重定向，否则被系统日志淹没）：

```bash
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO test > /tmp/silvics-test.log 2>&1
grep -E "Test Case.*(passed|failed)|TEST (SUCCEEDED|FAILED)" /tmp/silvics-test.log
```

数据库位置：`~/Library/Application Support/Silvics/silvics.sqlite`（WAL 模式）。可直接用 `sqlite3` 查证索引表：

```bash
sqlite3 "$HOME/Library/Application Support/Silvics/silvics.sqlite" \
  "select count(*) from note; select count(*) from link; select count(*) from mention;"
```

**不要用 `xcodebuild test -configuration Release`。** 测试目标是 `@testable import`，Release 下编译报 `Unable to resolve Swift module dependency`。需要 Release 性能数字时，用 `swiftc -O` 单独编 `MentionScanner.swift` + `StopWords.swift` 跑脚本。

### 本机已验证

```text
xcodegen generate                 → 生成工程
xcodebuild ... build              → BUILD SUCCEEDED
xcodebuild ... test               → 99 tests, 0 failures, TEST SUCCEEDED
open -a Silvics.app --env SILVICS_SEED=1
  → 21 条笔记 / 31 条边 / 2 条提及 / 5 个标签 / 1 条孤儿，数据正确
```

## 6. 截图与自动化验收

### 首选：App 自绘取证（不需要任何权限）

`Sources/Silvics/App/DebugCapture.swift`（仅 DEBUG）把窗口 `cacheDisplay` 成 PNG。不走 WindowServer，不需要屏幕录制授权，也不受窗口遮挡影响。

```bash
open -a .build/Build/Products/Debug/Silvics.app \
  --env SILVICS_CAPTURE=/tmp/reports/silvics-p3/01-main.png \
  --env SILVICS_SELECT=笔记标题应当写成断言句 \
  --env SILVICS_SHOW=quickopen|mentions|mentions-preview|alias|rename \
  --env SILVICS_RENAME_TO=分散重复优于集中突击
```

- `SILVICS_CAPTURE`：图片路径。可见窗口多于一个时写 `<name>-0.png`、`<name>-1.png`。
- `SILVICS_SELECT`：按标题子串选中笔记。
- `SILVICS_SHOW`：启动后直接打开某个面板。`mentions-preview` 会直接跳到 diff 预览。
- `SILVICS_RENAME_TO`：给改名面板预填新标题，用来看影响列表。

坑：`NSVisualEffectView`（侧栏选中行的材质）离屏栅格化会画成黑块。`DebugCapture` 捕获前把它们临时改成 `.contentBackground`，事后恢复。改动这块代码时别删那段。

### 备选：`screencapture`

- 单窗口：`screencapture -x -o -l<windowID> out.png`
- 取窗口 ID：编译 `/tmp/wininfo.swift`（`CGWindowListCopyWindowInfo`）。
- 本机 `screencapture` 无屏幕录制权限，报 `could not create image from display`。要真截屏得给 `Paseo.app` 授予「屏幕与系统音频录制」并完全重启它。
- 自动化按键（System Events）同样受限，`osascript` 会超时等授权。没有人工点一遍之前，不要声称界面已验收。

### 已有证据

`/tmp/reports/silvics-p3/`：主界面、带提及的笔记、Quick Open、提及面板、diff 预览、改名影响、别名面板（不入库）。

## 7. 必须知道的坑（已经踩过，别再踩）

1. **`swift-markdown` 的 `SourceLocation.column` 是 UTF-8 字节。** 不是字符，不是 UTF-16。回归测试 `testStrongRangeUsesUTF8Columns`。
2. **新增源文件后必须重跑 `xcodegen generate`。** 否则报「找不到符号」。
3. **先写的 `[[尚未存在的概念]]` 不会自动接上。** 每次 `save` 都调 `resolveAllLinks`。
4. **`resolveAllLinks` 必须把 `alias` 表算进去。** 只查 `note.titleKey` 会让 `[[别名]]` 在下次全库重算后错变成悬空。已修，`linkTargets(in:)` 是唯一入口。
5. **切换笔记会复用/重建 `NoteEditorView`，旧的 `NSPanel` 必须显式收掉。**
6. **`isRichText` 必须是 `true`。** 粘贴降级靠 `importsGraphics = false`。
7. **`App Sandbox` 必须关。**
8. **`link` / `mention` 表的位置列名是 `location`**，不要用 `offset`（SQLite 保留字）。
9. **`NLEmbedding` 的中文句向量不可用**（相关 0.9454 / 无关 0.9405）。L4 必须云端 BYOK。
10. **不要给 `swift-markdown` 加 `[[ ]]` 自定义语法。** 用自写 `WikiScanner`。
11. **`xcodebuild` 并发会锁 build.db。** 报 `database is locked` 时先 `pkill -f xcodebuild`。
12. **GRDB 的 `conn.changesCount` 是「最后一条语句」的变更数。** 在 `execute` 之后又跑了别的语句（例如重建索引），再读 `changesCount` 就是错的。已踩：`removeAlias` 曾因此永远返回 false。
13. **提及的归一化必须逐字符做。** 一个字符小写后可能变成多个标量（`İ` → `i̇`）。`MentionText.normalize` 记录每个标量对应的原文 UTF-16 起点与长度，区间才不会偏。
14. **自动机构建是 10 ms 量级（1000 条标题、12005 节点）。** 不能在每次按键时重建。`MentionIndex.scanner` 按标题集合指纹缓存，标题或别名变更才重建。
15. **提及与引用的写入顺序**：`reindex` → `resolveAllLinks` → `updateFTS` → `MentionIndex.reindex`，统一收在 `GRDBNoteRepository.reindexAll`。别在别处拆开写。

## 8. 已知缺陷与未做

| 项 | 说明 |
| --- | --- |
| 中文输入法未实测 | P1 遗留。需要人工在系统拼音输入法下敲一段中文。优先级最高 |
| P2 界面未人工验收 | 本机无屏幕录制权限，无法截图。逻辑有单测与数据库证据，视觉效果需人工确认 |
| 补全面板位置 | TextKit 2 下用 `layoutManager` 算光标矩形，多行折行处可能偏 |
| 补全不响应鼠标滚轮 | 列表超过 6 项时靠 ↑↓ |
| 提及下划线刷新延迟 | 保存是 500 ms 防抖，转换后下划线消失要等保存完成 |
| 批量转换的撤销只有一级 | 只记最近一次批量转换的正文快照。做第二次转换会覆盖 |
| 属性应用是全量 | 超过 5000 字的笔记会开始掉帧，设计文档 7.4 要改段落级增量 |
| `DebugLog` 与 `DemoSeeder` | 只在 DEBUG 编译 |
| `LineDiff` 大文本退化 | 行数乘积超过 250000 时不做 LCS，整块标记为变更 |
| 标签无改名 / 无删除入口 | 只能改正文里的 `#标签` 来增删 |
| Quick Open 不搜正文 | 只按标题。全文走侧栏搜索框 |
| 搜索没有高亮 | 摘要已居中到命中处，但正文里不高亮 |

## 9. 下一步：P4

按设计文档第 9 章。

1. **BYOK 设置**：服务商预设、Keychain 存 key、「测试连接」按钮。模型与预设见设计文档 8.6。
2. **L3 概念线索**：`NLTokenizer` 分词 + 停用词 + 词频，与库内标题模糊匹配，给「建立引用 / 新建笔记 / 忽略」三个动作。永不改正文。
3. **L4 相关笔记**：云端 embedding（`text-embedding-3-large` / `bge-m3` 等），阈值 0.82，标注「推测」。`NLEmbedding` 只做默认关闭的离线降级。
4. **未配 key 时的优雅降级**：L4 灰显并提示，L3 走纯本地路径。
5. 补测中文输入法（见第 8 节第一项）。

P4 验收标准：三个服务商各测通一次；未配 key 时功能不报错。

## 10. 不要做的事

- 不要引入第三方 Markdown 编辑器库。STTextView 是 GPLv3。
- 不要在 P3 之前做「隐藏 Markdown 语法标记」，风险见设计文档第 6 章。
- 不要让 L3/L4 改写用户正文。
- 不要把连接表当真源。真源永远是 `note.body`。
- 不要改 `~/.pi/agent/AGENTS.md`。项目规则只写本仓库的 `AGENTS.md`。

## 11. 历史决策记录

| 决策 | 结论 | 理由位置 |
| --- | --- | --- |
| Web 还是原生 | 原生 Swift | 设计文档第 6 章 |
| 应用名 | Silvics | 设计文档 11.1 |
| 编辑器 | 原生 NSTextView | 设计文档 7.3 |
| 存储 | GRDB + SQLite | 设计文档 7.1 |
| 引用解析 | 自写扫描器 | 设计文档 7.4 |
| 提及扫描 | Aho–Corasick + 指纹缓存 | 设计文档 8.4，本机 Release 0.035 ms |
| 提及门槛 | ≥4 汉字；中英混写 2 汉字即可；单拉丁词 ≥8 字符 | 实现时对设计文档的补充，见 `MentionGate` |
| L4 向量 | 云端 BYOK | 设计文档 8.5 |
| 语法渲染 | 保留标记 + 样式化 | 设计文档 7.4 |
| 批量转换的撤销 | 正文快照 + 菜单项，不用 `NSUndoManager` | 跨多篇笔记的程序化改写进不了同一个 undo 组 |
| 标签解析 | 自写 `TagScanner`，不用正则 | `#` 前后边界在中文标点上难写对；扫描还要排除代码与引用区间 |
| Quick Open 排序 | 前缀 → 包含 → 二元组 Jaccard | 1000 条标题在内存里排序，单次查询毫秒级，不需要索引 |
