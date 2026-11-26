# AGENTS.md

Silvics：单人用的 macOS 原生笔记应用。笔记正文是 Markdown 纯文本，写到已有标题时自动提示建立连接。

开工前先读这几份：

- `docs/设计文档.md` —— 设计取舍与本机实测数据（13 章）
- `docs/HANDOFF.md` —— 进度、已知坑、下一步
- `docs/RELEASE.md` —— 版本策略与发布脚本
- `docs/备份与同步.md` —— vault 格式、git 同步流程、合并与冲突规则
- `docs/笔记类型与元数据.md` —— 类型注册表、frontmatter 分层、未知键保留、sqlite 定位
- `docs/日记编辑器边界用例.md` —— 日记编辑器的边界用例（页内 77 条 + 端到端 28 条），实现时按编号写 XCTest

## 工作流：一个 issue 一个 worktree

**每个新 issue 开工前先开独立 worktree，不在主工作区动手。**

```bash
cd ~/work/dev/Silvics
git worktree add ~/work/dev/Silvics-<issue关键字> -b <type>/<issue关键字> main
cd ~/work/dev/Silvics-<issue关键字>
# 构建、测试、取证、提交全在这个目录里做；用完 git worktree remove 清掉
```

为什么：主工作区会同时有别的 agent 或另一条线在写。踩过的坑：

- 同一工作区里别人未提交的 `DebugCapture.swift` 被整文件 `git add` 带进了 PDF 剪藏那次提交，其中引用了尚未提交的 `EditorTextView.debugFlagsChangedCount`，**main 直接编不过**，只好补一次「撤回误并入」的提交。
- 别人的未提交改动会在主工作区里凭空出现又消失，`git status` 一会儿干净一会儿脏，验收截图与构建结果都无法信任。

配套纪律：

- **只 `git add` 自己写过的路径**，不要 `git add -A` / `git add .`。提交前 `git status --short` 逐行确认。
- 新 worktree 没有代理变量，SPM 会卡在 `Fetching from https://github.com/...`。构建前把 `DEVELOPER_DIR`、`HTTPS_PROXY`、`GIT_CONFIG_*` 按「环境」一节设好。
- 收尾删掉 worktree：`git worktree remove ~/work/dev/Silvics-<issue关键字>`（分支留着，等合并后再删）。

## 环境

| 项 | 值 |
| --- | --- |
| 系统 | macOS 27，Apple 芯片 |
| Xcode | 27.2，不在默认位置 |
| Swift | 6.4 |
| 工程生成 | xcodegen 2.48 |
| 依赖 | GRDB 7、swift-markdown（SPM 拉取） |

```bash
# 必须。不设会报「xcodebuild requires Xcode」。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

本机到 `github.com` 的 HTTPS 不通。首次构建卡在 `Fetching from https://github.com/...` 时挂代理：

```bash
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://127.0.0.1:7890
```

发布脚本也认 `SILVICS_SPM_PROXY=http://127.0.0.1:7890`，它会把上面三个变量一起设好。

依赖拉好后不再需要代理。SSH 推送、`api.github.com`、`uploads.github.com` 直连可用。

## 命令

```bash
# 生成工程。新增或删除 .swift 文件后必须重跑，否则报「找不到符号」。
xcodegen generate

# 构建
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO build

# 测试。输出必须重定向，否则被系统日志淹没。
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build \
  CODE_SIGNING_ALLOWED=NO test > /tmp/silvics-test.log 2>&1
grep -E "Test Case.*(passed|failed)|TEST (SUCCEEDED|FAILED)" /tmp/silvics-test.log

# 产物（`-derivedDataPath` 生效，路径固定）。用 open <路径>，不要用 open -a <相对路径>。
open .build/Build/Products/Debug/Silvics.app

# 带演示数据启动。仅 DEBUG，且仅在库为空时生效，灌 21 条互相引用的笔记。
rm -rf "$HOME/Library/Application Support/Silvics"
open .build/Build/Products/Debug/Silvics.app --env SILVICS_SEED=1

# 备份/同步：把库导成 vault 并推一次（面板里同样能点）
open .build/Build/Products/Debug/Silvics.app \
  --env SILVICS_VAULT=/tmp/vault --env SILVICS_REMOTE=/tmp/remote.git --env SILVICS_SYNC=1

# 重新生成 App 图标。.xcassets 在 sources 下自动收，不用重跑 xcodegen。
swiftc -O -o /tmp/icongen tools/icon/draw.swift
/tmp/icongen Sources/Silvics/Resources/Assets.xcassets /tmp/reports/silvics-icon
```

**不要跑 `-configuration Release` 的测试。** 测试目标用 `@testable import`，Release 下报 `Unable to resolve Swift module dependency`。需要 Release 性能数字就单独 `swiftc -O` 编相关文件。

## 发布

版本号只由脚本写，不要手改 `project.yml` 里的 `CFBundleShortVersionString` / `CFBundleVersion`，也不要手打 tag。

```bash
scripts/release.sh 0.1.1 --dry-run   # 只构建 + 打包，产物落 dist/
scripts/release.sh 0.1.1             # 提交版本号、打 tag、推送、建 GitHub Release
scripts/release.sh --rollback 0.1.1  # 删 release 与远端 / 本地 tag
scripts/release.sh --check-upload    # 验证上传通道
```

包是 ad-hoc 签名（无开发者证书），下载者首次打开需右键「打开」。细节见 `docs/RELEASE.md`。

## 测试

`Tests/SilvicsTests/`，XCTest，共 349 项（P1–P3、备份与同步、设置页、同步时机、冲突合并、类型注册表、日记、代码高亮）。

`EditorKit/` 与 `Core/` 不得导入 SwiftUI 或 AppKit 的 UI 部分。改这两个目录时先补失败测试再改实现。

不许删的回归测试：

- `testStrongRangeUsesUTF8Columns` —— `SourceLocation.column` 的单位是 UTF-8 字节。
- `testDanglingResolvesWhenTargetCreatedLater` —— 后建的目标笔记要接上已有悬空边。
- `testResolvedBecomesDanglingAfterRename` —— 目标改名后旧边要退回悬空。
- `testOverlappingPatternsAllReported` —— Aho–Corasick 的 `out` 要沿 fail 链合并。
- `testOffsetStaysCorrectAfterLengthChangingCharacter` —— 归一化逐字符映射 UTF-16 偏移。
- `testAliasProducesMentionAndResolvesLink` —— 别名既能产生提及，也能被 `[[ ]]` 解析。
- `testRenameRewritesBodies` —— 改名要改正文，并保留显示名与锚点。
- `testHeadingIsNotTag` —— ATX 标题的 `#` 不是标签。
- `testSearchFirstScreenUnderBudgetWithThousandNotes` —— 1000 条笔记搜索预算 100 ms。

## 硬约束

- `NSRange` 一律是 UTF-16 单位。`swift-markdown` 的 line/column 转区间必须走 `MarkdownStyler.buildByteToUTF16Map`。
- 正文是唯一真相。`note.body` 之外的表（link / mention / tag / FTS）都是索引，任何时候都能从正文重建。
- `[[ ]]` 解析用自写的 `WikiScanner`，不要改成 swift-markdown 自定义语法。
- `NSTextView.isRichText` 必须保持 `true`。
- App Sandbox 保持关闭，否则连不上本地 Ollama。
- `link` 与 `mention` 表的位置列名是 `location`，不要用 SQLite 保留字 `offset`。
- `resolveAllLinks` 必须把 `alias` 表算进去，唯一入口是 `linkTargets(in:)`。
- 提及扫描不得在按键时重建自动机，用 `MentionIndex.scanner(in:)`（按标题集合指纹缓存）。
- 新增笔记类型 = 加一个 `NoteType` 描述符 + 注册进 `NoteTypes.all`。列表、计数、搜索、提及、补全全部读描述符，不要写 `type == "..."`。
- 剪藏（`type=clip`）是单向引用：`emitsLinks=false`（正文不产边）、`isMentionTarget=false`（不进提及）、`inMainList=false`（不进「全部」与孤儿）、`tagsInBody=false`（标签读 `note.tags`）。
- `completionItems` 必须过滤 `linkable`；`rename` / `renameImpact` 只重写 `emitsLinks=true` 的正文。
- 剪藏标题不走 `validateTitle`，走 `ClipTitle`：去 Markdown 标记、换掉 `[ ] ( )`、日期式标题追加来源、重名追加来源或序号。日记标题是日期，撞上会建不出当天日记。
- `note.tags` 只给 `tagsInBody=false` 的类型用；其他类型文件里的 `tags:` 原样留在未知层，不能丢。
- 标签列表与计数必须带类型范围：概念侧栏不显示剪藏标签，剪藏范围不显示概念标签。
- manifest 哈希是整篇（frontmatter + 正文），`VaultFormat.manifestSchema = 2`。改哈希算法要同时改 `verify()` 与导入判定。
- 「同步剪藏」开关只在 `VaultSync.shouldSync(type:)` 判断；不要在导出、导入各写一份。
- 索引重算只能走 `reindexAll(note:in:)`，顺序：引用 → 引用解析 → FTS → 提及 → 标签。
- L3（概念抽取）与 L4（语义近邻）的建议永不改写用户正文。
- 模型服务的密钥只进 Keychain（`service=com.silvics.app.provider`，`account=provider-<uuid>`）。UserDefaults 与导出 JSON 里只有 `keyAccount` 引用，任何日志不得写明文。
- 单测不得碰真钥匙串：用 `InMemorySecretStore`。
- 本地服务（magpie / Ollama）靠 `ProviderConfig.requiresKey=false` 免密钥；不要靠填假 key 绕过。
- 冲突合并的模型输出必须先过 `ConflictResolver.clean` 与 `validate`：去分隔标记、拒冲突标记、拒异常长。
- 同步设置改动必须立即写 UserDefaults。不要再出现「只有点同步才保存」的实现。
- 同步跑不跑由 `SyncScheduler.shouldRun` 判定（启动 10 s / 定时间格 / 失败退避 5-15-60 / 有冲突不跑）。不要在别处另写一套判断。
- **vault 导出只写不删。** 库空了不能连带清空 vault（备份会一起没）。删除笔记走 `VaultSync.removeFromVault(id:)`。
- **绝不让 git 做合并。** `git merge` 会把冲突标记写进正文。合并走 `LineMerge`，git 只收已解决干净的提交。
- **判断 git 成败只看退出码。** `git remote get-url` 失败时也会往 stdout 写 `error: ...`，拿输出判空会误判。
- **`TextNormalizer.bodyHash` 必须跨进程稳定。** 用 SHA256，不要用 Swift `Hasher`（每进程随机加盐）。
- `MentionIndex.rebuildAll` 必须保留 `dismissed`（用户的决定不在正文里）。

## 分层与目录

```text
UI → App → Core / EditorKit     反向依赖不允许
```

- 新增源文件放 `Sources/Silvics/<层>/`，删加文件后重跑 `xcodegen generate`。
- 文档（设计、交接、发布）放 `docs/`；根目录只留 `README.md` 与 `AGENTS.md`。
- 图标母版是 `tools/icon/draw.swift`，不要手改 `Assets.xcassets` 里的 PNG；不要给 `AppIcon.appiconset` 加深色变体（deployment target 14 下 actool 会报 10 条 `unassigned children`）。

## 经验教训

按需增改。每条都带「为什么」和「怎么防」，只写踩过的，不写推测的。

1. **换结构比修 bug 便宜**：日记 v1 用结构化字段（`sections[].items[]`）存正文，模板段落成了固定槽位，于是「模块里加不进内容」这类问题修不完。改成「日记就是一份 Markdown 文本」后整类问题消失。动手前先问：这个结构允许用户做什么、禁止什么。
2. **一个约束消掉半类问题**：公式只当块级代码（```` ```latex ````），`$100 和 $200` 的歧义、`\$` 转义、代码里的 `$`、行内附件的复制语义全部不存在。设计时优先选约束，别急着加功能。
3. **真相只能有一个**：sqlite 曾同时是主存储、索引和缓存，三者迟早不一致。倒转成「先写文件、再更新索引」后，验收压成一句：删掉 `silvics.sqlite`，能从 vault 全量重建。
4. **未知数据原样保留**：frontmatter 里不认识的键、不认识的段，读进 `extra` 存着，写回一字不改。独立审查查出 5 处静默丢内容全属这一类。多版本共存时，删数据比不显示严重得多。
5. **测试要能抓红**：新增用例必须先在旧代码上跑红。把源码 stash 回旧版本重跑，10 条全红才证明测试有效。只跑新代码全绿说明不了任何事。
6. **验收必须真机跑**：批次 2 单测 257 项全绿，真机跑出 `vaultSeeded` 缺陷 —— 换 vault 目录后永不播种，此时删库丢 21 篇。这类缺陷单测测不出。
7. **断言按内容定位，不按行号或后缀**：端到端审计里 4 条「失败」全是断言写错（写死行号、`endsWith` 匹配不到带 `*` 的闭合围栏）。按行号断言，改一次文档就全废。
8. **边界用例编号化就是契约**：`S/E/T/C/X/H/L` 编号跨语言、跨实现都成立，是唯一能带进 Swift 的资产。代码会重写，用例不会。移植时按编号写 XCTest。
9. **测试不得碰真实状态**：不写真实 `UserDefaults`（用独立 suite）、不写 `~/Documents`（用临时 vault）。曾把本机提及开关设成 `true`，全量用例直接数组越界崩溃。
10. **页面级用例管逻辑，端到端审计管交互**：JS 原型里 77 条管解析与模型，28 条真键入/回车/粘贴管编辑行为。前者能直搬，后者要在目标平台重写。两套都跑过才算验完。

## 界面取证

优先让 App 自己画窗口，不需要任何 TCC 权限：

```bash
open .build/Build/Products/Debug/Silvics.app \
  --env SILVICS_CAPTURE=/tmp/reports/out.png \
  --env SILVICS_SELECT=标题关键字 \
  --env SILVICS_SHOW=quickopen|mentions|mentions-preview|alias|rename \
  --env SILVICS_RENAME_TO=新标题 \
  --env SILVICS_SELFTEST=convert
```

- 多个可见窗口时输出 `out-0.png`、`out-1.png`。
- `SILVICS_SELFTEST=convert` 合成一次 `⌘⇧K`，走真实 `keyDown` → `shouldChangeText` 链路。

冲突演练：`scripts/conflict-drill.sh`（两台设备改同一段 → diff3 冲突 → magpie 合并，打印耗时与结果）。

真截屏：`screencapture -x -o -l<windowID> out.png`（窗口 ID 用 `CGWindowListCopyWindowInfo`；`-l` 抓 sheet 会连父窗口一起捕获）。**注意 TCC 在进程启动时判定**：给宿主 App 授权后，除界面进程外还要重启常驻的 supervisor / daemon 侧进程。

窗口通道的三条实操：

- **先 `caffeinate -d -u -t 1800`**：显示器一睡，`screencapture` 拍出来是全黑的（或锁屏壁纸），而进程仍然活着，很容易误判成「窗口没画出来」。
- **避开本机正在用的 Silvics**：直接跑 Debug 产物会和用户那份抢焦点，`System Events` 按进程名找窗口会找到别人的。做法是把 `.app` 拷一份，改 `CFBundleName` / `CFBundleExecutable` / `CFBundleIdentifier`，`codesign --force --deep --sign - --identifier <新 id>` 重签，再按**自己的 pid** 找窗口（`CGWindowListCopyWindowInfo` 里有 `kCGWindowOwnerPID`）。
- **`screencapture -l<sheet id>` 返回的是父窗口画面**（含 sheet）。所以要先把主窗口 resize 到目标尺寸（`System Events` 设 `size of window 1`），再抓 sheet 的 id，出来的就是「主窗口 + 面板」的整块。

截图默认放 `/tmp/reports/silvics-*`。要贴进 issue 时，把报告与截图拷到 `docs/acceptance/<功能>-v<版本>/`（`report.md` + `artifacts/*.png`，图先 `sips -Z 1280` 压一遍），再链 GitHub 地址。

## 发版与验收

每次功能做完做两件事：发 release，把验收报告贴到 issue 评论。

### 版本号

- 修 bug：patch +1（`0.3.6` → `0.3.7`）。
- 加功能或改结构：minor +1（`0.4.0` → `0.4.1`）。
- 动数据格式或要迁移：才走 major。
- 版本号只由 `scripts/release.sh` 写入 `project.yml`。

### 验收报告

- 正文用 `shot-compare finish` 生成的 `report.md`。
- 不要手写报告，图片也不要手工拼。
- 报告五段：结论、用例表、偏差、未覆盖、复现命令。
- 证据必须是拼接图：并排、状态矩阵、2x 放大。
- 单张原图不算证据。
- 贴到对应 issue 评论，标题写版本号。

### 报告入库

- 放 `docs/acceptance/<功能>-v<版本>/`。
- 结构：`report.md` 加 `artifacts/*.png`。
- 图片先 `sips -Z 1280` 压一遍，整份 ≤ 2 MB。
- issue 评论里链这份报告的 GitHub 地址。

### 发版前检查

1. `xcodebuild test` 全过。
2. 报告齐，图能打开。
3. 跑过 `xctest-cache-clean.sh`。
