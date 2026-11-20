# AGENTS.md

Silvics：单人用的 macOS 原生笔记应用。Markdown 纯文本 + `[[ ]]` 引用 + 自动生成连接。
先读 `docs/设计文档.md`（设计与实测数据）与 `docs/HANDOFF.md`（进度、已知坑、下一步）。

## 命令

工程由 xcodegen 从 `project.yml` 生成。`Silvics.xcodeproj` 与 `Support/Info.plist` 是产物。

```bash
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

# 产物路径。不要假设在 .build 下，本机 BUILT_PRODUCTS_DIR 被重定向。
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -showBuildSettings 2>/dev/null | grep BUILT_PRODUCTS_DIR

# 带演示数据启动。仅 DEBUG 构建，且库为空时生效，灌 20 条互相引用的笔记。
rm -rf "$HOME/Library/Application Support/Silvics"
open -a "<BUILT_PRODUCTS_DIR>/Silvics.app" --env SILVICS_SEED=1
```

`xcodebuild` 并发会锁 `build.db`。报 `database is locked` 时先 `pkill -f xcodebuild`。

## 测试

测试文件 `Tests/SilvicsTests/EditorKitTests.swift`，XCTest，25 项。

改 `Sources/Silvics/EditorKit/` 或 `Sources/Silvics/Core/` 时，先补失败测试再改实现。
这两个目录不得导入 SwiftUI 或 AppKit 的 UI 部分，否则跑不了单测。

这三条是回归测试，改动时不许删：

- `testStrongRangeUsesUTF8Columns` —— `SourceLocation.column` 的单位是 UTF-8 字节。
- `testDanglingResolvesWhenTargetCreatedLater` —— 后建的目标笔记要自动接上已有的悬空边。
- `testResolvedBecomesDanglingAfterRename` —— 目标改名后旧边要退回悬空。

## 硬约束

- `NSRange` 一律是 UTF-16 单位。把 `swift-markdown` 的 line/column 转成区间，必须走 `MarkdownStyler.buildByteToUTF16Map`。按字符映射会让整篇中文样式错位。
- 正文是唯一真相。`note.body` 之外的表都是索引，任何时候都能从正文重建。不要在别处存连接状态。
- `[[ ]]` 解析用自写的 `WikiScanner`。不要改成 swift-markdown 的自定义语法。
- `NSTextView.isRichText` 必须保持 `true`。改成 `false` 会清掉程序化应用的属性。
- App Sandbox 保持关闭。开启后连不上本地 Ollama。
- `link` 表的时间列名是 `location`。不要改回 `offset`，SQLite 保留字。
- L3（概念抽取）与 L4（语义近邻）的建议永不改写用户正文。

## 目录约定

- 新增源文件放 `Sources/Silvics/<层>/`。依赖只允许 `UI → App → Core/EditorKit`，反向不行。
- 设计文档与交接文档放 `docs/`。
- 截图证据放 `/tmp/reports/silvics-*`，不入库。
- 截图取窗口 ID 用 `CGWindowListCopyWindowInfo`。`screencapture -l` 不包含 `NSPanel` 浮层，抓浮层要全屏再裁。
