# PDF 剪藏验收（v0.6.0，issue #30）

- 报告：`report.md`（由 `shot-compare` 生成，内嵌截图）
- 截图：`artifacts/`
- 夹具生成：`make-fixtures.swift`（`swiftc -O make-fixtures.swift -o /tmp/mkpdf && /tmp/mkpdf`，产物写 `/tmp/pdf-fix`）

## 怎么看

1. 先看 `report.md` 的用例表：8 条通过、3 条未覆盖、1 条偏差。
2. 截图是离屏渲染的 2x PNG。验收时机器锁屏，窗口通道出不了图，所以走 `SILVICS_OFFSCREEN`。
3. 复现命令写在 `report.md` 末尾。`SILVICS_CLIP_FILE` / `SILVICS_CLIP_URL` 只在 DEBUG 构建里生效，走的是真实导入链路。

## 本次没覆盖

- 拖拽导入（需要真实指针与窗口）
- 深色模式
- 100 MB 上限的实际夹具（只有单测）
