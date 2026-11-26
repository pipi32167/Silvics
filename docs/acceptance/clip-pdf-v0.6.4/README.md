# PDF 剪藏验收（v0.6.4，issue #30）

- 报告：`report.md`（`shot-compare` 生成，内嵌截图）
- 截图：`artifacts/`，全部是**真窗口截屏**（`screencapture -l`，屏幕未锁，窗口 1220×900）
- 夹具：`make-fixtures.swift`，跑 `swiftc -O make-fixtures.swift -o /tmp/mkpdf && /tmp/mkpdf` 生成到 `/tmp/pdf-fix`

## 和 v0.6.0 那份报告的区别

| 项 | v0.6.0 | 本份 |
| --- | --- | --- |
| 取证通道 | 离屏渲染（`SILVICS_OFFSCREEN`），当时机器锁屏 | 真窗口 `screencapture` |
| 拖拽用例 | 未覆盖 | 仍未覆盖：合成拖拽起不了 Finder 拖拽会话，`handleDrop` 一次没触发；落点已扩到整个面板 |
| 截断文案 | 「0.1 MB」 | 「48 KB」，不到 1 MB 说 KB |

## 本轮验收查出并修掉的两处

1. 提示写「把文件或网址拖到这里」，但 `.onDrop` 只挂在输入区，拖到面板下半部分没反应 → 挪到整个面板，加拖入高亮描边。
2. 61 页 48 KB 的 PDF 写成了「这份 PDF 0.0 MB」 → 不到 1 MB 说 KB。

## 测试范围

- 剪藏相关 45 项（`ClipPDFImportTests` / `ClipPDFIngestTests` / `ClipPDFFetchTests` / `ClipStoreTests` / `ClipIngestTests` / `ClipFileImportTests` / `EditorClipTests`）全过。
- 全量 562 项在 `d1bf939` 基线跑过全绿；本轮改动只碰拖拽落点与体积文案，按最小相关集重跑。
- 环境里同时有别的 agent 在跑 `xcodebuild` 并 `pkill` 构建进程，全量跑会被打断。

## 复现

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build

# 面板预览态（真实导入，不是拼图）
SILVICS_SHOW=new-clip SILVICS_CLIP_FILE=/tmp/pdf-fix/zh.pdf \
  SILVICS_VAULT=/tmp/v SILVICS_DB=/tmp/d.sqlite \
  .build/Build/Products/Debug/Silvics.app/Contents/MacOS/Silvics
```

`screencapture -x -o -l<窗口ID> out.png`；窗口 ID 按 pid 从 `CGWindowListCopyWindowInfo` 取（`kCGWindowOwnerPID`）。抓 sheet 的 id 会连父窗口一起截。

验收时机器上还开着用户在用的 Silvics，为避免抢焦点与截错窗口，把 Debug 产物拷一份并改 `CFBundleName` / `CFBundleIdentifier` 后重签，再按自己的 pid 找窗口。
