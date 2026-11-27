# Silvics 交接文档

写给接手这个项目的下一个 agent。读完这一份就能继续干活。

- 交接时间：2026-11-22
- 项目路径：`~/work/dev/Silvics`
- 当前阶段：P1、P2、P3 完成；备份与同步（git）、日记、设置、剪藏已合并；P5 未开始
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
│   ├── UI/
│       ├── RootView.swift      三栏 NavigationSplitView + 状态条
│       ├── SidebarView.swift   搜索、笔记列表
│       ├── EditorView.swift    NSTextView 桥、样式、补全、提及下划线、⌘⇧K
│       ├── CompletionPanel.swift  `[[` 补全浮层（无标题 NSPanel）
│       ├── ContextPanelView.swift 反向链接 / 提及 / 出链 / 悬空
│       ├── NewNoteSheet.swift  新建笔记 + 标题校验 + 查重
│       ├── MentionSheet.swift  未链接提及批量整理（选择 → diff → 转换）
│       ├── AliasSheet.swift    别名增删
│       └── RenameSheet.swift   改名 + 影响预览
│   └── Resources/
│       └── Assets.xcassets/    AppIcon（生成物）+ MenuBarIcon（未接入）
├── tools/icon/draw.swift       ← 图标生成器。图标只改这里，不要手改 PNG
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
| 单测 | 完成 | 88 项全过 |

额外修掉：`completionItems` 与短查询搜索里 `LIKE` 未转义 `%` / `_` 的 bug。

### 设置页（外观）

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| 设置窗口（`⌘,`） | 完成 | `NSWindowController` + `NavigationSplitView`，外观 / 关于两页 |
| 正文字号 / 代码字号 / 行距 | 完成 | 滑块即时生效，落 UserDefaults |
| 字体族（无衬线 / 衬线 / 等宽） | 完成 | 编辑区与预览同步 |
| 样式不进正文 | 完成 | `testBaseAttributesCarryCurrentFont` 等 13 + 5 项测试 |
| 模型服务（BYOK） | 完成 | 12 家预设 + 自定义、Keychain 存 key、测试连接（401 实测映射为中文）、L3/L4 各自绑定、未配置时提示原因 |
| 本地 LLM（magpie） | 完成 | 预设 `http://127.0.0.1:3425/v1`，`requiresKey=false`；模型列表拉取支持筛选 |
| 同步冲突 LLM 合并 | 完成 | `ConflictResolver` + `ChatClient`；drill 实测 2.7 s 合并成功 |
| 导入导出配置 | 完成 | JSON 不含密钥；重复服务导入时跳过 |
| 同步设置页 | 完成 | 并入设置窗口第四页；字段即时写本机，关窗不再丢配置 |
| 同步时机 | 完成 | 启动后 10 s 拉一次、定时（默认 15 分钟）、失焦 ≥5 分钟、手动 ⌘⇧Y；失败按 5/15/60 分钟退避 |
| 远端连通性检查 | 完成 | `git ls-remote` 10 s 超时，错误翻成中文（权限/不存在/解析/超时/指纹） |
| 恢复全部设置 | 完成 | 清 UserDefaults + 全部 `provider-*` 钥匙串项 |

`Theme` 从静态常量改为 `Theme.apply(settings)` 驱动；`AppearanceSettings` 存 UserDefaults（key `silvics.appearance.settings`），与 `SyncSettings` 一致。

模型服务：`ProviderService` 负责校验、增删、绑定、导入导出；`KeychainSecretStore` 只存密钥；`ProviderProbe` 拼 OpenAI 兼容 / Anthropic / Gemini 三种请求并做错误码映射。L3（概念线索）与 L4（相关笔记）本体还没做，等 P4 接上 `effective(_:)`。

本地 LLM：magpie 在 `127.0.0.1:3425` 提供 OpenAI 兼容代理，无鉴权，`auto/*` 是路由组；`ProviderConfig.requiresKey=false` 时 `effective` 不要求密钥。magpie **没有** `/v1/embeddings`，L4 用不了。

同步设置从独立 `SyncSheet` 并入设置窗口的「同步」页。**旧版有关窗丢配置的 bug**：当时只有点「立即同步 / 从 vault 恢复 / 校验」才 `persist()`，直接关窗什么都不写。现在字段改动防抖 400 ms 写 UserDefaults，`onDisappear` 再兜底。

同步时机（`Core/SyncScheduler`，纯函数 + 单测）：启动 10 s 后一次；定时按 `backgroundSync` 与 `syncIntervalMinutes`（默认开、15 分钟，可选 5/10/15/30/60）；切到别的 App 后若距上次 ≥5 分钟再同步一次；退出前不做网络操作（避免卡住退出）。失败退避 5 → 15 → 60 分钟，有冲突或正在同步时一律不跑。`autoSync` 这个死字段已删。

同步冲突合并：`VaultSync.lastConflicts` 收集 diff3 合不了的正文，`ConflictResolver` 用对话模型合并，校验后由用户在 `ConflictSheet` 确认。演练：`scripts/conflict-drill.sh`，结论见 `docs/测试-双客户端冲突.md`。

### P3

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| `⌘P` Quick Open | 完成 | `QuickOpenSheet`，前缀 → 包含 → 二元组相似度排序，空查询给最近更新 |
| 孤儿笔记视图 | 完成 | 侧栏「孤儿笔记」范围 + `⌘⇧O`，演示数据 21 条里有 1 条 |
| 标签 | 完成 | `TagScanner` 扫 `#标签`（跳过 ATX 标题、代码块、行内代码、`[[ ]]`、URL） |
| 标签筛选 | 完成 | 侧栏标签列表按使用次数排序，点击切范围 |
| 搜索摘要 | 完成 | 以命中处为中心取片段，前后加省略号 |
| 搜索性能 | 完成 | 1000 条笔记，Debug 实测 **4.7 ms**（验收线 100 ms） |
| 单测 | 完成 | 88 项全过 |

### 图标

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| App 图标 | 完成 | 生长枝 + 叶 + 递减琥珀点 + 断开的点；绿/琥珀取自 `Theme.swift` |
| 尺寸 | 完成 | 10 个尺寸进 `Assets.car`；`assetutil --info` 核对完整 |
| 小尺寸适配 | 完成 | ≤ 32px 走加粗参数，16px 仍是「Y + 一点」 |
| 深色变体 | 未接入 | 只在 deployment target ≥ 26 时 actool 才收，本项目 14.0 |
| Dock 实测 | 完成 | `NSWorkspace.icon(forFile:)` 取 512 / 128 / 32 / 16 全部为本图 |

取证图在 `/tmp/reports/silvics-icon/`，入库的只有 `docs/images/app-icon.png`（1024）与 `app-icon-128.png`（README 用）。

### 备份与同步（分支 `feat/vault-sync`）

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| vault 导出（md + frontmatter + manifest） | 完成 | 幂等：连续导出两次，第二次写 0 个文件 |
| 别名与已忽略提及进 vault | 完成 | 单测 `testAliasesAndDismissedSurviveRoundTrip` |
| 从 vault 恢复 | 完成 | 清空数据库后启动，imported=21，库回到 21 笔记 / 31 边 / 5 标签 |
| git 双向同步 | 完成 | 本机 bare 仓库当远端，两台「设备」互推互拉，6 个集成测试 |
| 三方合并 | 完成 | `LineMerge`（diff3），不同位置改动自动合，同行冲突留档 |
| 冲突留档 | 完成 | `.conflicts/` 存两份原文，正文不留 `<<<<<<<` |
| 校验 | 完成 | manifest 哈希、条数、与远端差集四项 |
| 面板 | 完成 | `⌘⇧B`；观感证据是 `ImageRenderer` 离屏渲染，不是窗口截图 |
| 单测 | 完成 | 134 项全过（原 99 + 35 新增） |

设计说明见 [备份与同步.md](备份与同步.md)。

顺手修了两个存量 bug：`TextNormalizer.bodyHash` 用 `Hasher` 跨进程不稳定；`MentionIndex.rebuildAll` 会清掉 `dismissed`。

### 日记批次（分支 `feat/journal-save-invert`）

设计见 [笔记类型与元数据.md](笔记类型与元数据.md) 第 6、7 节。

| 批次 | 验收项 | 状态 | 证据 |
| --- | --- | --- | --- |
| 1 | `type` + 类型注册表 + `meta` 类型段 + frontmatter 分层与未知键保留 + v2 迁移 | 完成 | `NoteTypeTests` |
| 2 | 保存倒转：先写 vault 文件，再更新 sqlite 索引 | 完成 | `NoteWriterTests` 10 项；`SILVICS_INVERT_DRILL` 两次启动演练 40 个字段全一致 |

批次 2 的三条新约束：

- 保存 = 编码 → 比字节（没变就一个字节都不碰）→ 原子写 → 写库 + 重算这一篇索引。文件失败不写库，库失败标 `meta.indexDirty=1` 并抛错。
- `GRDBNoteRepository(db:vaultURL:)` 可注入目录，默认取 `SyncSettings.load().vaultURL`。**测试必须传临时目录**（`TempVault`）。
- 启动自愈 `repairFromVaultIfNeeded()`：库空或 `indexDirty=1` 而 vault 有文件时全量导入并清标记。库空 + vault 空时**不写任何标记**，下次启动继续重试。
- 播种 `seedVaultIfNeeded()` 只看**当前 vault 目录**：库里有多篇而 `notes/` 里没有 `.md` 就导出一遍。旧版本用 `meta.vaultSeeded` 当全局开关，换目录后不再播种（新目录一直空），已废弃：旧键搬到 `legacyVaultSeeded` 留痕，当前目录记在 `vaultSeededPath`，两者都不参与判断。
- 演练：`SILVICS_VAULT_SWITCH_DRILL=<dir>` + `SILVICS_DRILL_STEP=write|switch|rebuild`，三次启动之间由 shell `rm silvics.sqlite`。

改名、别名、批量转换、撤销、忽略提及这些「直接改库」的老通路，事后走 `NoteWriter.flush` 把文件补齐。

### 日记：批次进度

| 批次 | 内容 | 状态 |
| --- | --- | --- |
| 1 | 类型注册表 + frontmatter 分层 | 已合入 |
| 2 | 保存链路倒转（先写文件，再写库） | 已合入 |
| 3 | 模板与待办融合、按类型落目录 | 已合入（融合在 issue #48 里改成按段并入） |
| 4 | 日记编辑器（光标行露源码） | 已合入 |
| 5 | 代码高亮 | 已合入 |
| 6 | 交叉影响与待办总览 | 已合入（余项：模板记忆在本分支 `feat/journal-b6-rest`） |
| 7 | 发布 | 未做 |

批次 6 余项（分支 `feat/journal-b6-rest`）：

- **待办融合（issue #48，替换原先的「承接段」）**：`JournalMerge.merge(into:from:)`。
  用 `swift-markdown` 的 AST 定位，取上一篇里 `checkbox == .unchecked` 的条目，
  按标题路径（`["工作","部署"]`）并进当天同名段的最后一个非空行之后。
  判重按整篇待办文本，出现过就跳过；缺段按来源层级在文末补标题链。
  写入是纯文本按行插入，**不重新序列化整篇**（否则表格对齐、行内样式、git diff 全变）。
  界面上点「融合」（编辑区标题栏，日记才出现），或新建日记时自动跑一次。
  `journal.carryFrom` 记来源日，右栏显示「融合自」。
- **模板记忆**：`JournalTemplateMemory`（`UserDefaults` 键 `silvics.journal.templateNames`）。
  新建时 `JournalTemplates.newJournalNames` 先按记忆取（按当前 order 排序，文件没了的跳过），
  一个都不剩才退回 order 最小的前两个。编辑区标题栏「模板…」勾选即覆盖记忆，只影响下次新建。

0.2.0 发布内容：批次 1–6 全部合入 main（类型注册表、保存倒转、模板与承接、混合模式编辑器、
代码高亮、界面接入与待办总览）。已知限制：日记文件落在 `journal/<日期>.md`。旧 vault 里 `notes/` 下的日记（如果有）读入时
按「目录与类型一致优先」去重（`VaultFormat.dedupe`），旧目录那份仍在磁盘上；保存时按 `updated:`
保留较新的一份，另一份写进 `.trash/`，不直接删。

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

### 发布

```bash
scripts/release.sh 0.1.1 --dry-run   # 只构建 + 打包
scripts/release.sh 0.1.1             # 提交版本号、打 tag、推送、建 Release
```

版本号只由脚本写进 `project.yml`。细节见 `docs/RELEASE.md`。

- 当前线上版本：**v0.1.3**（2026-11-24）。DMG 3.6 MB，ad-hoc 签名，arm64。
- 版本历史：0.1.0 写作内核 → 0.1.1 vault 备份与 git 同步 → 0.1.2 设置页 / BYOK / 本地 magpie / 冲突 LLM 合并 → 0.1.3 同步设置并入设置窗口（修关窗丢配置）。
  sha256 `1818e531390d8ab0c79c7fc48d1d21dea4a3b6085c09975a93e19cbefa00fbaa`。
  0.1.1 内容：笔记真相层从 sqlite 挪到 vault 目录，新增导出/恢复/校验、git 双向同步、diff3 合并。
- 发布脚本会问一次 `继续？[y/N]`。非交互跑要 `<<< "y"`，否则只构建不发布。
- 坑：`release.sh` 中途中断会留下改过的 `project.yml`，重跑前先 `git checkout -- project.yml`，否则预检「工作区不干净」。
- 上传通道已验证：`scripts/release.sh --check-upload`（建 draft → 传资产 → 删除）。
- 下载回来的 dmg 与本地产物 sha256 一致。
- 坑：无开发者证书时 `codesign --sign -` 只能 ad-hoc。下载者首次打开要右键「打开」，或 `xattr -d com.apple.quarantine`。
- 坑：`xcodebuild -showBuildSettings` 不带 `-derivedDataPath` 会返回默认 DerivedData 路径，产物路径直接用 `.build/Build/Products/Release`。
- 坑：shell 里 `$VAR` 紧跟中文会被吞进变量名，必须写 `${VAR}`。

### 本机已验证

```text
xcodegen generate                 → 生成工程
xcodebuild ... build              → BUILD SUCCEEDED
xcodebuild ... test               → 88 tests, 0 failures, TEST SUCCEEDED
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

### 真截屏：`screencapture`（已可用）

2026-11-24 起本机已给 `Paseo.app` 授予「屏幕与系统音频录制」，`screencapture` 正常。

```bash
screencapture -x -o -l<windowID> out.png      # 单窗口（sheet 会连父窗口一起捕获）
screencapture -x /tmp/full.png                # 整屏，再裁
```

- 取窗口 ID：编译 `/tmp/wininfo.swift`（`CGWindowListCopyWindowInfo`）。sheet 是独立窗口，`-l` 抓 sheet 会把父窗口一起带进来。
- **权限坑**：TCC 在进程启动时判定。给 Paseo 授权后，界面进程重启不够——真正 fork 出命令的 `Paseo Supervisor` / `Paseo Daemon` 也要重启，否则一直报 `could not create image from display`。验证用 `CGPreflightScreenCaptureAccess()`。
- **自动化按键仍不可用**：`osascript` 报 `not allowed to send keystrokes / 不允许辅助访问`，因为「辅助功能」没有授权。要驱动鼠标键盘，得再给 Paseo 授「辅助功能」并重启常驻进程。

### 真点击 / 真按键（辅助功能已授权）

`osascript ... click at` 只发 `AXPress`，不移动光标，**不能**用来测编辑器。要真点击用 CGEvent：

```bash
# /tmp/ui.swift：ui click <x> <y> | ui key <keycode> cmd|cmdshift
/tmp/ui click 900 367      # 真实鼠标点击（会落光标）
/tmp/ui key 40 cmdshift    # ⌘⇧K
```

坐标换算是 **屏幕点 = 窗口原点 + 截图内坐标**。窗口截图是 1x 点尺寸，整屏截图是 2x。

已用这条路验过（2026-11-24）：

| 动作 | 结果 |
| --- | --- |
| 点进提及 → `⌘⇧K` | 正文变成 `[[标题]]`，mention 2→1，link 31→32 |
| `⌘⇧M` → 全选 → 看 diff → 确认转换 | mention 2→0，link 31→33，两篇正文改写 |
| 转换完成 → 撤销这次转换 | mention 回到 2，link 回到 31，正文复原 |
| `⌘P` → 粘贴查询 → `↩` | 打开正确笔记 |
| `⌘⇧R` → 改标题 → 重命名 | 标题改掉，旧标题进别名，正文引用改写，悬空 0 |
| `⌘⇧A` → 加别名 / 加冲突别名 | 正常新增；冲突时提示「已有同名笔记，别名会与它冲突」 |

`↩` 要发 `key code 36`，CGEvent 直接发虚拟键 36 在这台机器上没反应，用 `osascript -e 'tell application "System Events" to key code 36'` 可靠。

### 替代：合成事件自测

不给辅助功能也能验证编辑器快捷键：`SILVICS_SELFTEST=convert` 会在启动后 2.5 秒把光标放进第一条提及，并合成一个 `⌘⇧K` 事件丢给 `NSTextView.keyDown`。走的是真实链路（`keyDown` → `shouldChangeText` → 改写 → 防抖保存），只是绕开系统键盘。

```bash
open -a .build/Build/Products/Debug/Silvics.app \
  --env SILVICS_SEED=1 --env SILVICS_SELECT=笔记标题应当写成断言句 --env SILVICS_SELFTEST=convert
# 之后查库：正文应出现 [[标题]]，mention 少一条，link 多一条
```

### 已有证据

- `/tmp/reports/silvics-p3-real/`：真截屏（带窗口阴影与系统控件），P3 全部界面。
- `/tmp/reports/silvics-p3/`：`DebugCapture` 自绘图，同一个界面，作对照。

均不入库。

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
15. **深色图标别写进 `AppIcon.appiconset`。** `appearances: luminosity/dark` 在 deployment target 14.0 下不被 actool 接收，每次构建报 10 条 `unassigned children`。等切 Icon Composer（macOS 26 起）再加。生成器会把深色母版落到预览目录。
16. **`AppIcon.icns` 只有 16/32/128/256 四个尺寸，是正常的。** actool 瘦身所致，10 个尺寸在 `Assets.car` 里。Dock 走 `CFBundleIconFile` → `Assets.car`，别照 icns 的尺寸数下结论。
17. **图标不要手改 `Assets.xcassets` 里的 PNG。** 母版是 `tools/icon/draw.swift`，重跑一行命令就全覆盖。
18. **`pkill -f "Silvics.app/Contents/MacOS/Silvics"` 会连执行它的 shell 一起杀掉**（命令行里含同样的字符串，退出码 143）。用 `pkill -f "[S]ilvics.app/Contents/MacOS"`。
19. **`open -a <相对路径>` 报「Unable to find application」**。用 `open .build/Build/Products/Debug/Silvics.app`。
20. **提及与引用的写入顺序**：`reindex` → `resolveAllLinks` → `updateFTS` → `MentionIndex.reindex`，统一收在 `GRDBNoteRepository.reindexAll`。别在别处拆开写。

## 8. 已知缺陷与未做

| 项 | 说明 |
| --- | --- |
| 中文输入法未实测 | P1 遗留。需要人工在系统拼音输入法下敲一段中文。优先级最高 |
| 界面验收方式 | 2026-11-24 起「辅助功能」已授权，用 CGEvent 真点击 + 真按键跑通了全部链路，见第 6 节 |
| 补全面板位置 | TextKit 2 下用 `layoutManager` 算光标矩形，多行折行处可能偏 |
| 补全不响应鼠标滚轮 | 列表超过 6 项时靠 ↑↓ |
| 提及下划线刷新延迟 | 保存是 500 ms 防抖，转换后下划线消失要等保存完成 |
| 批量转换的撤销只有一级 | 只记最近一次批量转换的正文快照。做第二次转换会覆盖 |
| 撤销栈按「编辑器实例」存在 | 换笔记即丢弃上一篇的撤销历史（issue #35 的取舍：宁可没有，也不能退到别的笔记）。要跨切换保留，得把栈提到 `AppState` 按 note id 存 |
| 撤销每步存全文快照 | 上限 200 步。100 KB 正文最坏 20 MB；未做大数据量计时 |
| 属性应用是全量 | 超过 5000 字的笔记会开始掉帧，设计文档 7.4 要改段落级增量 |
| `DebugLog` 与 `DemoSeeder` | 只在 DEBUG 编译 |
| `LineDiff` 大文本退化 | 行数乘积超过 250000 时不做 LCS，整块标记为变更 |
| 标签无改名 / 无删除入口 | 只能改正文里的 `#标签` 来增删 |
| Quick Open 不搜正文 | 只按标题。全文走侧栏搜索框 |
| 搜索没有高亮 | 摘要已居中到命中处，但正文里不高亮 |
| 深色 / 着色图标未接入 | 母版已在生成器里，需 deployment target ≥ 26 或转 Icon Composer |
| MenuBarIcon 未接入 | 资源已进 catalog，界面还没用；将来加托盘才接线 |
| 图标无 3D / 材质 | 纯扁平双色。macOS 26 的 Liquid Glass 图标要另做，当前是保守的 Big Sur 风格 |
| 日记文件仍在 `notes/` | `NoteType.fileDir` 已定义 `journal/`，但 vault 读、导出、保存都还只认 `notes/`。类型目录留到批次 3 一起做 |
| 改 vault 目录不需要重启 | `AppState.saveSyncSettings` 会把新目录同步给仓库。但已经写过旧目录的文件不会自动搬过去 |

### 剪藏（issue #6，分支 feat/clips）

- 类型层：`NoteTypes.clip`，`clips/<id>.md`。描述符新增 `emitsLinks` / `isMentionTarget` / `inMainList` / `tagsInBody`。
- 数据：迁移 `v3` 加 `note.tags`（JSON 数组）。frontmatter 顶层 `tags:` 只对剪藏写；`clip:` 段存 url/site/author/published/sourceTitle/summary/clipStatus/aiState/aiModel。
- 单向：`reindex` 跳过 `emitsLinks=false`；改名只重写会解析引用的类型；提及自动机只收 `isMentionTarget=true`。
- 同步：列表字段（aliases / dismissed / tags）改三方集合合并；manifest 与导入判定改整篇哈希（manifest schema 2）。
- 设置：模型服务加「剪藏整理」用途（未绑定跟随对话模型）；新增「剪藏」页；同步页加「同步剪藏」开关；关于页显示剪藏统计。
- 界面：侧栏剪藏范围（未读 / 全部 / 已归档 / 标签），中间栏复用 Typora 式编辑器只读渲染，右栏来源 / 摘要 / 标签 / 被引用 / 操作。`⌘⇧V` 新建，`⌘⇧L` 切范围。
- PDF 剪藏已做（issue #30，0.6.0）：PDFKit 按页取文字层，字形折回常用字，扫描件/加密件走粘贴兜底，网址直连 PDF 同样支持。未做：OCR、批量 URL、浏览器扩展。

### AI 提问（issue #45，0.7.0）

- 右栏加「详情 / AI」两个页签，三个模块都能用。没有选中笔记时是「全局提问」（会话 id `_global`）。
- 会话落 `<vault>/ai/<note-id>.jsonl`，一条消息一行 JSON。字段带引用、证据、模型名、token，跨设备合并后都在。
- 清空写 `role=clear` 标记，不删文件。合并时用最新标记截断它之前的消息。
- 合并：`AIConversation.merge` 按 `id` 去重 → 按 `at` 排序 → 用最新清空标记裁。`VaultSync.resolveRemote` 先合并远端会话再交给 git。
- manifest schema 2 → 3，加 `conversations`（id / hash / updated）。`verify()` 会查会话漂移。
- 上下文：系统提示词带笔记标题、正文、引用；证据只进本轮提问。截断顺序是先丢最早历史，再截正文（`AIContextBuilder`）。
- 设置页「AI 提问」：系统提示词、4 条内置提示词（可改不可删）、正文上限 0/4000/8000/20000、历史轮数 3/5/10/20。
- 快捷键：`⌘⌥A` 切到 AI 页，`⌘⇧Q` 引用选中内容。
- 未做：流式输出、外部联网服务（DeepSeek Web Tools / Tavily 已核额度未接）、会话加密。
- 验收：`docs/acceptance/ai-chat-v0.7.0/report.md`。取证钩子：`SILVICS_AI_PROVIDER=1`、`SILVICS_SHOW=ai-chat|ai-quote|ai-evidence|ai-sending|ai-error|ai-details|settings-ai`、`SILVICS_CONTEXT_WIDTH`、`SILVICS_SETTINGS_SIZE`。

## 9. 下一步：P5

1. **P5 图**：局部图（当前笔记 2 跳内）与全局图。剪藏默认不进图。
2. **L3 概念线索**：分词 + 停用词 + 词频，与库内标题模糊匹配，给「建立引用 / 新建笔记 / 忽略」。永不改正文。
3. **L4 相关笔记**：云端 embedding，阈值 0.82，标注「推测」。
4. ~~**PDF 剪藏**~~：issue #30 已在 0.6.0 完成。
5. 补测中文输入法（见第 8 节第一项）。

P5 验收标准：1000 条笔记下局部图 60 fps。

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
