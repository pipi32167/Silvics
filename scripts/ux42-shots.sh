#!/bin/bash
# issue #42 体验优化：截图取证。
#
# 用窗口级 screencapture（-l <windowid>），不用 App 自绘：
# 自绘在侧栏 vibrancy 上会留黑块（0.7.0 报告已记过）。
# 每个用例跑两遍：第一遍把 vault 建好，第二遍才截图，避免「写入 vault」的状态条入镜。
set -u
APP=$HOME/work/dev/Silvics/.build/Build/Products/Debug/Silvics.app/Contents/MacOS/Silvics
OUT=/tmp/reports/silvics-ux-issue42/artifacts/raw
ROOT=/tmp/ux42-vault
mkdir -p "$OUT" "$ROOT"

# 界面偏好会跨进程落盘。每个用例前都重置，否则上一张的模块栏收起、字号会带进下一张。
reset_prefs() {
  defaults write com.silvics.app silvics.nav.collapsed -bool NO
  defaults write com.silvics.app silvics.nav.listVisible -bool YES
  defaults write com.silvics.app "silvics.nav.listWidth" -float 232
  defaults delete com.silvics.app silvics.appearance.settings 2>/dev/null
}

stop() { pkill -f "Silvics.app/Contents/MacOS/Silvics" 2>/dev/null; sleep 0.5; }

launch() { # launch <vault> <seconds> [env...]
  local vault="$1"; local wait="$2"; shift 2
  mkdir -p "$vault"
  env SILVICS_NO_KEYCHAIN=1 SILVICS_VAULT="$vault" "$@" "$APP" > "/tmp/ux42-run.log" 2>&1 &
  sleep "$wait"
}

shot() { # shot <name> [env...]
  local name="$1"; shift
  local vault="$ROOT/${name%%-*}"
  stop
  reset_prefs
  launch "$vault" 6 "$@"          # 预热：建 vault、写演示数据
  stop
  launch "$vault" 6 "$@"
  local id
  id=$(/tmp/winid Silvics | awk 'NR==1{print $1}')
  if [ -z "${id:-}" ]; then echo "FAIL $name: 没有窗口"; stop; return; fi
  screencapture -x -o -l "$id" "$OUT/$name.png"
  stop
  if [ -f "$OUT/$name.png" ]; then
    echo "ok   $name  $(sips -g pixelWidth "$OUT/$name.png" | tail -1 | awk '{print $2}')x$(sips -g pixelHeight "$OUT/$name.png" | tail -1 | awk '{print $2}')"
  else
    echo "FAIL $name"
  fi
}

W=SILVICS_WINDOW=1280x880
D=SILVICS_SHOW=details

shot 01-nav-notes       $W SILVICS_SEED=1 $D
shot 02-nav-journal     $W SILVICS_SEED=1 SILVICS_SHOW=journal
shot 03-nav-clips       $W SILVICS_SHOW=clips-all
shot 04-nav-collapsed   $W SILVICS_SHOW=clips-all $D SILVICS_NAV_COLLAPSED=1
shot 05-ai-default      $W SILVICS_SEED=1 SILVICS_SHOW=ai-chat
shot 06-ai-small        $W SILVICS_SEED=1 SILVICS_SHOW=ai-chat SILVICS_APPEARANCE=panel=11
shot 07-ai-large        $W SILVICS_SEED=1 SILVICS_SHOW=ai-chat SILVICS_APPEARANCE=panel=18
shot 08-settings-appear SILVICS_SEED=1 SILVICS_SHOW=settings
shot 09-dark-clips      $W SILVICS_SHOW=clips-all SILVICS_DARK=1
shot 10-dark-ai         $W SILVICS_SEED=1 SILVICS_SHOW=ai-chat SILVICS_DARK=1
shot 11-newclip         SILVICS_SEED=1 SILVICS_SHOW=new-clip SILVICS_WINDOW=980x760
shot 12-journal-scope   $W SILVICS_SEED=1 SILVICS_SHOW=journal
ls -1 "$OUT"
