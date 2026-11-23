# AGENTS.md

Silvics：单人用的 macOS 原生笔记应用。Markdown 纯文本 + `[[ ]]` 引用 + 自动生成连接。
先读 `docs/设计文档.md`（设计与实测数据）与 `docs/HANDOFF.md`（进度、已知坑、下一步）。

## 命令

工程由 xcodegen 从 `project.yml` 生成。`Silvics.xcodeproj` 与 `Support/Info.plist` 是产物。

```bash
# 本机 Xcode 不在默认位置，必须设。不设会报「requires Xcode」。
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 生成工程。新增 .swift 文件后必须重跑，否则编译报「找不到符号」。
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

# 查产物路径（本机固定为 .build/Build/Products/Debug/Silvics.app）
ls .build/Build/Products/Debug/Silvics.app

# 带演示数据启动。仅 DEBUG 构建，且库为空时生效，灌 20 条互相引用的笔记。
rm -rf "$HOME/Library/Application Support/Silvics"
open -a .build/Build/Products/Debug/Silvics.app --env SILVICS_SEED=1
```

### SPM 拉依赖卡住

本机到 `github.com` 的 HTTPS 不通。首次构建卡在 `Fetching from https://github.com/...` 时挂代理：

```bash
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 ALL_PROXY=http://127.0.0.1:7890
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://127.0.0.1:7890
```

依赖拉好后不再需要代理。SSH 推送与 `api.github.com` 直连可用。

### 不要跑 Release 测试

测试目标用 `@testable import`，`-configuration Release` 下报 `Unable to resolve Swift module dependency: 'Silvics'`。要 Release 性能数字就单独 `swiftc -O` 编相关文件。

## 测试

测试文件在 `Tests/SilvicsTests/`，XCTest，共 99 项（P1 27 + P2 46 + P3 26）。

`EditorKit/` 与 `Core/` 不得导入 SwiftUI 或 AppKit 的 UI 部分，否则跑不了单测。

改 `EditorKit/` 或 `Core/` 时，先补失败测试再改实现。

这三条是回归测试，改动时不许删：

- `testStrongRangeUsesUTF8Columns` —— `SourceLocation.column` 的单位是 UTF-8 字节。
- `testDanglingResolvesWhenTargetCreatedLater` —— 后建的目标笔记要自动接上已有的悬空边。
- `testResolvedBecomesDanglingAfterRename` —— 目标改名后旧边要退回悬空。

P2 新增的回归测试，同样不许删：

- `testOverlappingPatternsAllReported` —— Aho–Corasick 的 `out` 要沿 fail 链合并。
- `testOffsetStaysCorrectAfterLengthChangingCharacter` —— 归一化逐字符映射 UTF-16 偏移。
- `testAliasProducesMentionAndResolvesLink` —— 别名既要能产生提及，也要能被 `[[ ]]` 解析。
- `testRenameRewritesBodies` —— 改名要改正文，并保留显示名与锚点。
- `testHeadingIsNotTag` —— ATX 标题的 `#` 不是标签。
- `testSearchFirstScreenUnderBudgetWithThousandNotes` —— 1000 条笔记搜索预算 100 ms。

## 硬约束

- `NSRange` 一律是 UTF-16 单位。把 `swift-markdown` 的 line/column 转成区间，必须走 `MarkdownStyler.buildByteToUTF16Map`。按字符映射会让整篇中文样式错位。
- 正文是唯一真相。`note.body` 之外的表都是索引，任何时候都能从正文重建。不要在别处存连接状态。
- `[[ ]]` 解析用自写的 `WikiScanner`。不要改成 swift-markdown 的自定义语法。
- `NSTextView.isRichText` 必须保持 `true`。改成 `false` 会清掉程序化应用的属性。
- App Sandbox 保持关闭。开启后连不上本地 Ollama。
- `link` 表的时间列名是 `location`。不要改回 `offset`，SQLite 保留字。`mention` 表同理。
- `resolveAllLinks` 必须把 `alias` 表算进去。唯一入口是 `GRDBNoteRepository.linkTargets(in:)`。
- 提及扫描不得在按键时重建自动机。用 `MentionIndex.scanner(in:)`，它按标题集合指纹缓存。
- 索引重算只能走 `reindexAll(note:in:)`。顺序：引用 → 引用解析 → FTS → 提及 → 标签。
- L3（概念抽取）与 L4（语义近邻）的建议永不改写用户正文。

## 目录约定

- 新增源文件放 `Sources/Silvics/<层>/`。依赖只允许 `UI → App → Core/EditorKit`，反向不行。
- 设计文档与交接文档放 `docs/`。
- 截图证据放 `/tmp/reports/silvics-*`，不入库。
- **优先用 `DebugCapture` 取证，不要等屏幕录制授权。** 它让 App 自己把窗口画成 PNG，不需要任何 TCC 权限：

  ```bash
  open -a .build/Build/Products/Debug/Silvics.app \
    --env SILVICS_CAPTURE=/tmp/reports/out.png \
    --env SILVICS_SELECT=标题关键字 \
    --env SILVICS_SHOW=quickopen|mentions|mentions-preview|alias|rename \
    --env SILVICS_RENAME_TO=新标题
  ```

  多个可见窗口（主窗 + sheet）时输出 `out-0.png`、`out-1.png`。
- 本机 `screencapture` 没有屏幕录制权限，直接跑报 `could not create image from display`。要真截屏得先给 Paseo 授权并重启它。
- 需要 `screencapture` 时用 `CGWindowListCopyWindowInfo` 取窗口 ID。`-l` 不包含 `NSPanel` 浮层，抓浮层要全屏再裁。
