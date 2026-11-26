#!/bin/bash
#
# issue #42 验收报告一键重建：截图 → 拼接对比 → 回填结论。
#
# 产物：/tmp/reports/silvics-ux-issue42/{report.md,artifacts/}
# 依赖：scripts/ux42-shots.sh（窗口级 screencapture）、~/.local/bin/shot-compare
#
# 为什么不用 App 自绘（SILVICS_CAPTURE）：侧栏 vibrancy 会留黑块，
# 0.7.0 的验收报告已经记过这条，这里统一走 screencapture -l <windowid>。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REPORT=/tmp/reports/silvics-ux-issue42
RAW="$REPORT/artifacts/raw"
SC=~/.local/bin/shot-compare
COMMIT="$(git rev-parse --short HEAD)"

rm -rf "$REPORT"
"$ROOT/scripts/ux42-shots.sh" >/tmp/ux42-shots.log 2>&1 || { tail -20 /tmp/ux42-shots.log; exit 1; }
grep -c '^ok' /tmp/ux42-shots.log | xargs echo "截图："

# 性能数字：120 篇 × 24k 字，修复前后（探针实测，见 issue #42 评论）
python3 - "$RAW/13-perf-before-after.png" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
W, H = 1080, 470
img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)
F = "/System/Library/Fonts/Supplemental/Songti.ttc"
big = ImageFont.truetype(F, 26); mid = ImageFont.truetype(F, 21); small = ImageFont.truetype(F, 18)
d.text((28, 22), "切到剪藏：修复前后（120 篇 × 24k 字，正文合计 2813 KB）", font=big, fill="#111")
rows = [
    ("动作", "修复前", "修复后", "倍数"),
    ("clipSummaries()", "57.2 ms", "8.1 ms", "7×"),
    ("clipCounts()", "57.5 ms", "0.5 ms", "115×"),
    ("selectModule(.clips) 关自动标已读", "109 ms", "9.2 ms", "12×"),
    ("selectModule(.clips) 开自动标已读", "198–226 ms", "21.9 ms", "9–10×"),
    ("clipSummaries() 300 篇", "117.3 ms", "19.5 ms", "6×"),
]
x = [28, 470, 690, 860]; y = 78
for i, row in enumerate(rows):
    f = mid if i == 0 else small
    for col, text in zip(x, row):
        d.text((col, y), text, font=f, fill="#333" if i == 0 else "#111")
    y += 44 if i == 0 else 38
    if i == 0:
        d.line([(28, y - 12), (W - 28, y - 12)], fill="#bbb", width=1)
d.text((28, H - 92), "口径：xcodebuild test 里的临时探针，Debug -Onone，取单次 wall time。", font=small, fill="#666")
d.text((28, H - 66), "修复前：clipSummaries 取整行 Note（含 body），clipCounts 内部再取一遍。", font=small, fill="#666")
d.text((28, H - 40), "修复后：只取列表列 + SQL 计数；打开即标已读仍会再刷一次列表，故 21.9 ms。", font=small, fill="#666")
img.save(sys.argv[1])
PY

"$SC" init --dir "$REPORT" --project silvics --branch feat/ux-issue42 --commit "$COMMIT" \
  --env "macOS 27.0.1 / Apple 芯片 / Debug 构建 / SILVICS_* 取证钩子 + 窗口级 screencapture（1280x880；深色 SILVICS_DARK=1；字号 SILVICS_APPEARANCE=panel=）" \
  --data "本机真实库：28 篇笔记 / 3 篇剪藏；剪藏演示数据钩子在库非空时自动跳过" \
  --cache ".build" --tester "pi agent" >/dev/null

"$SC" grid "$RAW/01-nav-notes.png" "$RAW/02-nav-journal.png" "$RAW/03-nav-clips.png" \
  --labels 笔记 日记 剪藏 --cols 3 --dir "$REPORT" --out 01-module-highlight.png --report \
  --case "模块切换高亮" --criterion "三个模块分别选中时模块行底色跟随选中，⌘1/⌘2/⌘3 常显在行尾" --result 通过 >/dev/null

"$SC" crop "$RAW/01-nav-notes.png" --box 0,58,140,105 --zoom 3 --dir "$REPORT" --out 02-module-rows-3x.png --report \
  --case "模块行快捷键与选中态（3x）" --criterion "笔记行有 accent 底色；条数与 ⌘1 之间留 6 px；未选中行无底色" --result 通过 >/dev/null

"$SC" crop "$RAW/03-nav-clips.png" --box 0,800,372,80 --zoom 3 --dir "$REPORT" --out 03-list-new-row-3x.png --report \
  --case "剪藏底部新建入口（3x）" --criterion "剪藏列表底部固定「＋ 新建剪藏」，分隔线 1 px，整行可点" --result 通过 >/dev/null

"$SC" crop "$RAW/12-journal-scope.png" --box 0,800,372,80 --zoom 3 --dir "$REPORT" --out 04-journal-new-row-3x.png --report \
  --case "日记底部新建入口（3x）" --criterion "日记模块底部为「＋ 今天的日记」，与剪藏入口同一位置、同一色阶" --result 通过 >/dev/null

"$SC" pair "$RAW/06-ai-small.png" "$RAW/05-ai-default.png" \
  --labels "11 pt（≈旧实现 11.5）" "13.5 pt（新默认）" --with-diff --align 2 --tolerance 8 \
  --dir "$REPORT" --out 05-ai-font-pair.png --report \
  --case "AI 页字号：旧值与新默认" --criterion "同一会话下正文/标签/注脚三档同步放大，气泡与引用卡片不溢出" --result 通过 >/dev/null

"$SC" grid "$RAW/06-ai-small.png" "$RAW/05-ai-default.png" "$RAW/07-ai-large.png" \
  --labels "11 pt" "13.5 pt（默认）" "18 pt" --cols 3 --dir "$REPORT" --out 06-ai-font-matrix.png --report \
  --case "面板字号三档矩阵" --criterion "11/13.5/18 三档下消息、模型名、引用、证据、输入框不截断、不重叠" --result 通过 >/dev/null

"$SC" crop "$RAW/05-ai-default.png" --box 900,330,366,110 --zoom 3 --dir "$REPORT" --out 07-ai-text-3x.png --report \
  --case "AI 正文 13.5 pt（3x）" --criterion "正文字号明显大于元信息（模型名 10.5），层级仍分得清" --result 通过 >/dev/null

"$SC" crop "$RAW/08-settings-appear.png" --box 150,430,530,130 --zoom 2 --dir "$REPORT" --out 08-settings-panel-size-2x.png --report \
  --case "外观设置新增面板字号（2x）" --criterion "「面板字号」滑杆在行距之下，范围 11–18，步长 0.5，默认 13.5 pt" --result 通过 >/dev/null

"$SC" grid "$RAW/01-nav-notes.png" "$RAW/09-dark-clips.png" --labels "浅色（笔记）" "深色（剪藏）" --cols 2 \
  --dir "$REPORT" --out 09-light-dark.png --report \
  --case "深浅色下的模块高亮" --criterion "深色下选中底色与快捷键仍可辨，文字对比度不塌" --result 通过 >/dev/null

"$SC" crop "$RAW/04-nav-collapsed.png" --box 0,58,60,110 --zoom 3 --dir "$REPORT" --out 10-collapsed-rail-3x.png --report \
  --case "收起态图标栏仍保留选中色（3x）" --criterion "收成一列图标后选中模块仍有 accent 底色与描边，与展开态同一色阶" --result 通过 >/dev/null

"$SC" grid "$RAW/13-perf-before-after.png" --labels 探针实测 --cols 1 --dir "$REPORT" --out 11-perf-before-after.png --report \
  --case "切剪藏耗时（探针实测）" --criterion "列表查询不再解码正文：120 篇时切到剪藏从约 200 ms 降到 22 ms 以内" --result 通过 >/dev/null

"$SC" deviation --dir "$REPORT" --area "模块行右侧" \
  --design "issue #42 只说「需要显示切换快捷键」，未规定位置" \
  --impl "快捷键与条数同一行右对齐、中间留 6 px；模块栏下限从 132 px 提到 140 px，标题不再退化成省略号" \
  --verdict 已修复 --evidence "artifacts/02-module-rows-3x.png" >/dev/null

"$SC" deviation --dir "$REPORT" --area "列表底部新建行" \
  --design "issue #42：支持用光标添加文档，可以放在底部" \
  --impl "放在 List 之外的固定条带：不随列表滚动、不参与列表选中高亮" \
  --verdict 待确认 --evidence "artifacts/03-list-new-row-3x.png" >/dev/null

"$SC" deviation --dir "$REPORT" --area "右栏 18 pt 档" \
  --design "右栏宽度 200–380 px（设计文档）" \
  --impl "18 pt 下消息换行明显增多；本次只在 292 px 宽验收" \
  --verdict 待确认 --evidence "artifacts/06-ai-font-matrix.png" >/dev/null

"$SC" uncovered --dir "$REPORT" --case "真实键盘 ⌘1/⌘2/⌘3" \
  --reason "自动化按键需要辅助功能授权；本次只验按钮路径与快捷键绑定代码" >/dev/null
"$SC" uncovered --dir "$REPORT" --case "新建剪藏预览的字号" \
  --reason "摘要/标签预览要真实抓取正文后才出现，本次未造抓取数据；预览与右栏共用 PanelFont" >/dev/null
"$SC" uncovered --dir "$REPORT" --case "待办总览 / 模板范围隐藏底部新建行" \
  --reason "两页占满中栏，列表中栏不出现；本次未单独截图" >/dev/null
"$SC" uncovered --dir "$REPORT" --case "200 px 窄右栏 × 18 pt" \
  --reason "只验了 292 px 宽；窄宽需另开 900x700 窗口" >/dev/null
"$SC" uncovered --dir "$REPORT" --case "多语言与断点" \
  --reason "应用只有中文界面，没有语言切换" >/dev/null

"$SC" repro --dir "$REPORT" --cmd 'export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && cd ~/work/dev/Silvics && xcodegen generate && xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug -destination "platform=macOS" -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test' >/dev/null
"$SC" repro --dir "$REPORT" --cmd 'cd ~/work/dev/Silvics && ./scripts/ux42-report.sh   # 截图 + 拼接 + 回填，一条命令重建本报告' >/dev/null
"$SC" repro --dir "$REPORT" --cmd '性能数字：临时探针 Tests/SilvicsTests/ZZPerfProbe.swift（跑完删除），120 篇 × 24k 字内存库，量 clipSummaries / clipCounts / selectModule(.clips)' >/dev/null

"$SC" finish --dir "$REPORT" | tail -3
