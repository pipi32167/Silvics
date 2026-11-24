# AGENTS.md

Silvics：单人用的 macOS 原生笔记应用。笔记正文是 Markdown 纯文本，写到已有标题时自动提示建立连接。

开工前先读三份：

- `docs/设计文档.md` —— 设计取舍与本机实测数据（13 章）
- `docs/HANDOFF.md` —— 进度、已知坑、下一步
- `docs/RELEASE.md` —— 版本策略与发布脚本
- `docs/备份与同步.md` —— vault 格式、git 同步流程、合并与冲突规则

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

`Tests/SilvicsTests/`，XCTest，共 178 项（P1–P3、备份与同步、设置页、冲突合并）。

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
- 索引重算只能走 `reindexAll(note:in:)`，顺序：引用 → 引用解析 → FTS → 提及 → 标签。
- L3（概念抽取）与 L4（语义近邻）的建议永不改写用户正文。
- 模型服务的密钥只进 Keychain（`service=com.silvics.app.provider`，`account=provider-<uuid>`）。UserDefaults 与导出 JSON 里只有 `keyAccount` 引用，任何日志不得写明文。
- 单测不得碰真钥匙串：用 `InMemorySecretStore`。
- 本地服务（magpie / Ollama）靠 `ProviderConfig.requiresKey=false` 免密钥；不要靠填假 key 绕过。
- 冲突合并的模型输出必须先过 `ConflictResolver.clean` 与 `validate`：去分隔标记、拒冲突标记、拒异常长。
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

截图放 `/tmp/reports/silvics-*`，不入库。
