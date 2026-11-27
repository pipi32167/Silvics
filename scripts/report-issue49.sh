#!/bin/bash
# 重建 issue #49 验收报告（每跑一次都会覆盖 report.md，所以放在一个脚本里按顺序跑完）。
set -e
SC=~/.local/bin/shot-compare
DIR=/tmp/reports/silvics-fix-ime-render-issue49
OLD=/tmp/ab-old-shots
NEW=/tmp/ab-new-shots
rm -rf "$DIR"

$SC init --dir "$DIR" --project silvics --branch fix-ime-render-issue49 \
  --commit "$(cd ~/work/dev/Silvics-ime-render && git rev-parse --short HEAD)+工作区" \
  --env "macOS 27 / Xcode 27.2 / Swift 6.4 / Debug / App Sandbox 关" \
  --data "SILVICS_DB 临时库 + SILVICS_SEED=1；自检把一篇含各类 markdown 的正文装进编辑区" \
  --cache "SPM SourcePackages 复用，DerivedData .build" --tester pi >/dev/null

$SC pair "$OLD/shot-03-composing.png" "$NEW/shot-03-composing.png" \
  --labels 旧实现-0.8.0 新实现-fix-ime-render --align 2 --tolerance 8 --with-diff \
  --dir "$DIR" --out 01-组字中-整窗.png \
  --case "01 组字中：整窗前后对比" \
  --criterion "组字期间：组字行不出现复选框；其余每条待办都在自己那一行且勾选态与本行是否打勾一致" \
  --result 通过 --note "旧实现：组字行多出一个勾选方框，下面七条待办整体串态一格；新实现全部对上" \
  --sub "issue #49 · 中文输入法组字渲染" --meta "900x1050 DPR2" --report --keep-raw >/dev/null

$SC crop "$OLD/shot-03-composing.png" --box 160,140,360,540 --zoom 2 --dir "$DIR" --out 02-raw-旧实现-裁剪.png >/dev/null
$SC crop "$NEW/shot-03-composing.png" --box 160,140,360,540 --zoom 2 --dir "$DIR" --out 02-raw-新实现-裁剪.png >/dev/null
$SC pair "$DIR/artifacts/02-raw-旧实现-裁剪.png" "$DIR/artifacts/02-raw-新实现-裁剪.png" \
  --labels 旧实现 新实现 --align 2 --tolerance 8 --dir "$DIR" --out 02-组字中-复选框2x细节.png \
  --case "02 组字中：复选框细节 2x 放大" \
  --criterion "逐行核对：已完成的一组打勾 / 未完成的另一组空框 / 拿口罩打勾 / 买牛奶空框 / 迁移打勾 / 修改空框；组字行不该有方框" \
  --result 通过 --note "旧实现从组字行开始整体串一格；新实现七个方框全部落回自己那一行" \
  --sub "issue #49 细节放大" --meta "360x540 裁切 · 2x" --report --keep-raw >/dev/null

$SC pair "$OLD/shot-05-composing-wrap.png" "$NEW/shot-05-composing-wrap.png" \
  --labels 旧实现-0.8.0 新实现-fix --align 2 --tolerance 8 --with-diff \
  --dir "$DIR" --out 03-组字换行-整窗.png \
  --case "03 组字换行：整窗前后对比" \
  --criterion "组字串长到换行、下面整体下移时：复选框跟着下移并保持各自勾选态；引用竖线、代码块底色不跑到别的段落" \
  --result 通过 --note "旧实现：七个方框全挤到组字那一行，生活标题左边多出一个方框，工作区冒出一条竖线；新实现全部归位" \
  --sub "issue #49 · 块级装饰按字符偏移自绘" --meta "900x1050 DPR2" --report --keep-raw >/dev/null

$SC crop "$OLD/shot-05-composing-wrap.png" --box 160,300,360,320 --zoom 2 --dir "$DIR" --out 04-raw-旧实现-裁剪.png >/dev/null
$SC crop "$NEW/shot-05-composing-wrap.png" --box 160,300,360,320 --zoom 2 --dir "$DIR" --out 04-raw-新实现-裁剪.png >/dev/null
$SC pair "$DIR/artifacts/04-raw-旧实现-裁剪.png" "$DIR/artifacts/04-raw-新实现-裁剪.png" \
  --labels 旧实现 新实现 --align 2 --tolerance 8 --dir "$DIR" --out 04-引用竖线与复选框-2x细节.png \
  --case "04 组字换行：引用竖线 / 方框细节 2x" \
  --criterion "工作区三条待办各自带方框、勾选态与正文一致；引用竖线只画在引用块左侧；生活标题左侧无方框" \
  --result 通过 --note "旧实现竖线串到工作区、方框堆在组字行；新实现竖线回到引用块、方框归位" \
  --sub "issue #49 细节放大" --meta "360x320 裁切 · 2x" --report --keep-raw >/dev/null

$SC grid "$NEW/shot-01-rendered.png" "$NEW/shot-03-composing.png" "$NEW/shot-04-committed.png" \
  --labels 渲染态 组字中 上屏后 --cols 3 --dir "$DIR" --out 05-新实现-状态矩阵.png \
  --case "05 新实现：渲染态 → 组字中 → 上屏后" \
  --criterion "三态下待办方框数量、位置、勾选态一致；组字中只有组字那一行露源码；上屏后回到渲染态" \
  --result 通过 --note "组字不改渲染，只改正文；三态画面除组字行外一致" \
  --sub "issue #49 状态矩阵" --meta "900x1050 DPR2 x3" --report --keep-raw >/dev/null

$SC crop "$NEW/shot-01-rendered.png" --box 160,520,360,520 --zoom 2 --dir "$DIR" --out 06-raw-组字前-裁剪.png >/dev/null
$SC crop "$NEW/shot-03-composing.png" --box 160,520,360,520 --zoom 2 --dir "$DIR" --out 06-raw-组字中-裁剪.png >/dev/null
$SC pair "$DIR/artifacts/06-raw-组字前-裁剪.png" "$DIR/artifacts/06-raw-组字中-裁剪.png" \
  --labels 组字前 组字中 --align 2 --tolerance 8 --dir "$DIR" --out 06-其他组件-组字前后.png \
  --case "06 其他 markdown 组件：组字前后渲染不变" \
  --criterion "引用（竖线 + 次级色）、行内代码（等宽 + 底色）、粗体、斜体、引用链接（下划线）、表格（等宽 + pipe 对齐）、代码块（底色 + 关键字上色）在组字前后逐项一致" \
  --result 通过 --note "裁切区为工作 / 阅读 / 表格 / 代码块；差异只在组字行，下面组件零改动" \
  --sub "issue #49 其他组件核对" --meta "360x520 裁切 · 2x" --report --keep-raw >/dev/null

$SC crop "$OLD/shot-03-composing.png" --box 160,660,360,120 --zoom 4 --dir "$DIR" --out 07-raw-旧实现-裁剪.png >/dev/null
$SC crop "$NEW/shot-03-composing.png" --box 160,660,360,120 --zoom 4 --dir "$DIR" --out 07-raw-新实现-裁剪.png >/dev/null
$SC pair "$DIR/artifacts/07-raw-旧实现-裁剪.png" "$DIR/artifacts/07-raw-新实现-裁剪.png" \
  --labels 旧实现 新实现 --align 2 --tolerance 8 --dir "$DIR" --out 07-行内强调-区间修正4x.png \
  --case "07 行内强调 / 行内代码：块引用懒惰续行的区间修正 4x" \
  --criterion "行内代码的反引号、双星号粗体、单星号斜体的定界符全部隐藏，只剩等宽底色与粗体 / 斜体字形；正文一个字符不改" \
  --result 通过 --note "旧实现整行右移两位：露出双星号与单星号，粗体落到「粗 + 两个星号」上；新实现定界符全部隐藏" \
  --sub "issue #49 顺带修掉的同类渲染缺陷" --meta "360x120 裁切 · 4x" --report --keep-raw >/dev/null

$SC uncovered --dir "$DIR" --case "系统拼音输入法真机敲字" \
  --reason "本机 TISSelectInputSource 返回 -50（paramErr），进程内外都切不到简体拼音输入源（同 issue #34 记录）。自检按 NSTextInputClient 协议（setMarkedText → insertText）等价驱动编辑区，仍需人工在系统拼音下敲一次确认"
$SC uncovered --dir "$DIR" --case "深色外观" \
  --reason "缺陷是「偏移过期导致装饰画错行」，与配色无关；本次未取深色图"
$SC uncovered --dir "$DIR" --case "表格行内组字" \
  --reason "表格块要光标行撤 kern 才露源码，组字与表格 kern 的组合本次未单独取图；由 06 的表格区间核对与 R08 的区间用例覆盖"
$SC uncovered --dir "$DIR" --case "窄 / 宽窗口断点" \
  --reason "只取 900x1050 一种窗口宽度；换行触发靠 05 的长组字串覆盖，未做多断点矩阵"

$SC repro --dir "$DIR" --cmd 'xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug -destination "platform=macOS" -derivedDataPath .build CODE_SIGNING_ALLOWED=NO -only-testing:SilvicsTests/EditorComposeRenderTests -only-testing:SilvicsTests/StylerTests test'
$SC repro --dir "$DIR" --cmd 'SILVICS_DB=/tmp/ab/db.sqlite SILVICS_VAULT=/tmp/ab/vault SILVICS_SEED=1 SILVICS_SELFTEST=ime-render SILVICS_CAPTURE=/tmp/ab/shot.png SILVICS_QUIT_AFTER_SELFTEST=1 .build/Build/Products/Debug/Silvics.app/Contents/MacOS/Silvics'

$SC finish --dir "$DIR"
