#!/bin/bash
#
# 两台设备改同一篇笔记 → 冲突 → 用本地 LLM 合并。取证用。
#
# 用法：
#   scripts/conflict-drill.sh            # 跑一次，打印合并结果
#   scripts/conflict-drill.sh --keep     # 保留临时仓库供检查
#
# 依赖：已构建的 Debug 版 App；「设置 → 模型服务」里已绑定可用的对话模型（magpie / Ollama / 云端均可）。

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Build/Products/Debug/Silvics.app"
LOG="${TMPDIR:-/tmp}/silvics-drill/drill.log"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

[ -d "$APP" ] || { echo "先构建 Debug 版：xcodebuild ... build"; exit 1; }

rm -rf "${TMPDIR:-/tmp}/silvics-drill"
pkill -f "[S]ilvics.app/Contents/MacOS" 2>/dev/null || true
sleep 1

open "$APP" --env SILVICS_CONFLICT_DRILL=1 --env SILVICS_SEED=1

for _ in $(seq 1 40); do
  [ -f "$LOG" ] && break
  sleep 1
done

if [ ! -f "$LOG" ]; then
  echo "超时：没等到 drill.log。确认 App 已启动、Debug 构建。"
  exit 1
fi

cat "$LOG"

if [ "$KEEP" = "0" ]; then
  pkill -f "[S]ilvics.app/Contents/MacOS" 2>/dev/null || true
fi
