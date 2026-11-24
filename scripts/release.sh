#!/bin/bash
#
# Silvics 发布脚本。版本、构建、ad-hoc 签名、DMG、打 tag、传 GitHub Release。
#
# 用法：
#   scripts/release.sh 0.1.1                  # 完整发布
#   scripts/release.sh 0.1.1 --dry-run        # 只构建与打包，不提交、不打 tag、不上传
#   scripts/release.sh --check-upload         # 只验证 GitHub 上传通道（建 draft 再删）
#   scripts/release.sh --rollback 0.1.1       # 删 release、删远端 tag、删本地 tag
#
# 版本策略：0.1.0 起，小改 patch +1；阶段完成升 minor。
# 版本号只由本脚本写进 project.yml，不要手改。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="Silvics"
PROJECT="Silvics.xcodeproj"
DERIVED=".build"
DIST="dist"
APP_NAME="Silvics.app"
REPO="pipi32167/Silvics"
TAG_PREFIX="v"

# 本机 Xcode 不在默认位置
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# 首次构建要拉 SPM 依赖。github.com 直连不通时用本地代理。
if [ -n "${SILVICS_SPM_PROXY:-}" ]; then
  export HTTPS_PROXY="$SILVICS_SPM_PROXY" HTTP_PROXY="$SILVICS_SPM_PROXY" ALL_PROXY="$SILVICS_SPM_PROXY"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0="$SILVICS_SPM_PROXY"
fi

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m失败：\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 小工具 ----------

project_version() {
  sed -n 's/.*CFBundleShortVersionString: "\([^"]*\)".*/\1/p' project.yml | head -1
}

project_build() {
  sed -n 's/.*CFBundleVersion: "\([^"]*\)".*/\1/p' project.yml | head -1
}

write_version() {
  local version="$1" build="$2"
  python3 - "$version" "$build" <<'PY'
import io, re, sys
version, build = sys.argv[1], sys.argv[2]
path = 'project.yml'
s = io.open(path, encoding='utf-8').read()
s = re.sub(r'CFBundleShortVersionString: "[^"]*"', f'CFBundleShortVersionString: "{version}"', s, count=1)
s = re.sub(r'CFBundleVersion: "[^"]*"', f'CFBundleVersion: "{build}"', s, count=1)
io.open(path, 'w', encoding='utf-8').write(s)
PY
}

next_build_number() {
  echo $(( $(git rev-list --count HEAD) + 1 ))
}

require_clean_tree() {
  if [ -n "$(git status --porcelain)" ]; then
    git status --short
    die "工作区不干净，先提交或还原。"
  fi
}

# ---------- 预检 ----------

preflight() {
  say "预检"
  [ -d "$DEVELOPER_DIR" ] || die "找不到 Xcode：$DEVELOPER_DIR"
  command -v xcodegen >/dev/null || die "缺 xcodegen（brew install xcodegen）"
  command -v gh >/dev/null || die "缺 gh（brew install gh）"
  gh auth status >/dev/null 2>&1 || die "gh 未登录，先 gh auth login"
  ok "工具齐备，gh 已登录"
}

check_upload_channel() {
  say "验证 GitHub 上传通道"
  local tmp asset tag
  tmp="$(mktemp -d)"
  asset="$tmp/upload-probe.txt"
  printf 'silvics upload probe\n' > "$asset"
  tag="upload-probe-$(date +%s)"

  gh release create "$tag" "$asset" \
    --repo "$REPO" --draft --title "上传探测" --notes "临时 draft，用于验证上传通道。" >/dev/null \
    || die "建 draft release 失败"
  ok "已建 draft：$tag"

  local uploaded
  uploaded="$(gh release view "$tag" --repo "$REPO" --json assets --jq '.assets | length')"
  gh release delete "$tag" --repo "$REPO" --yes >/dev/null
  rm -rf "$tmp"

  [ "$uploaded" = "1" ] || die "上传后资产数为 ${uploaded}，通道不可用"
  ok "上传通道可用，draft 已清理"
}

# ---------- 构建 ----------

build_app() {
  say "生成工程"
  xcodegen generate >/dev/null
  ok "$PROJECT"

  say "Release 构建（arm64）"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    build > "${TMPDIR:-/tmp}/silvics-release-build.log" 2>&1 \
    || { tail -30 "${TMPDIR:-/tmp}/silvics-release-build.log"; die "构建失败"; }

  APP_PATH="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -showBuildSettings 2>/dev/null | sed -n 's/ *BUILT_PRODUCTS_DIR = //p' | head -1)/$APP_NAME"
  [ -d "$APP_PATH" ] || die "找不到产物：$APP_PATH"
  ok "$APP_PATH"
}

verify_app() {
  local version build
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
  [ "$version" = "$TARGET_VERSION" ] || die "Info.plist 版本是 ${version}，期望 $TARGET_VERSION"
  ok "版本 ${version}（${build}）"

  say "ad-hoc 签名"
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1
  codesign --verify --strict "$APP_PATH" || die "签名校验失败"
  ok "$(codesign -dv "$APP_PATH" 2>&1 | sed -n 's/^Signature=//p')"
  xattr -cr "$APP_PATH"
}

package_dmg() {
  say "打包 DMG"
  rm -rf "$DIST/dmg-root"
  mkdir -p "$DIST/dmg-root"
  cp -R "$APP_PATH" "$DIST/dmg-root/"
  ln -s /Applications "$DIST/dmg-root/Applications"

  DMG_PATH="$DIST/Silvics-$TARGET_VERSION.dmg"
  rm -f "$DMG_PATH"
  hdiutil create -quiet -volname "Silvics" -srcfolder "$DIST/dmg-root" \
    -ov -format UDZO "$DMG_PATH" || die "hdiutil 打包失败"
  hdiutil verify -quiet "$DMG_PATH" || die "DMG 校验失败"
  rm -rf "$DIST/dmg-root"

  SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  ok "$DMG_PATH"
  ok "大小 $(du -h "$DMG_PATH" | awk '{print $1}')，sha256 ${SHA256:0:16}…"
}

# ---------- 发布 ----------

release_notes() {
  local notes="$DIST/release-notes.md" prev
  prev="$(git describe --tags --abbrev=0 2>/dev/null || true)"

  {
    echo "## Silvics $TARGET_VERSION"
    echo
    if [ -n "${RELEASE_SUMMARY:-}" ]; then
      echo "$RELEASE_SUMMARY"
      echo
    fi
    echo "单人用的 macOS 原生笔记应用。Markdown 纯文本 + \`[[ ]]\` 引用 + 自动生成连接。"
    echo
    echo "### 变更"
    echo
    if [ -n "$prev" ]; then
      git log --no-merges --pretty=format:'- %s' "$prev..HEAD" | grep -v '^- chore(release)' || true
    else
      git log --no-merges --pretty=format:'- %s' | grep -v '^- chore(release)' || true
    fi
    echo
    echo
    echo "### 安装"
    echo
    echo "1. 下载 \`Silvics-$TARGET_VERSION.dmg\`，双击挂载。"
    echo "2. 把 Silvics 拖进「应用程序」。"
    echo "3. 首次打开：在 Finder 里右键 App →「打开」→ 再点「打开」。"
    echo
    echo "或先去掉隔离标记："
    echo
    echo '```bash'
    echo "xattr -d com.apple.quarantine /Applications/Silvics.app"
    echo '```'
    echo
    echo "本包是 ad-hoc 签名（无 Apple 开发者证书），未做公证。系统会提示「无法验证开发者」，这是预期行为。"
    echo
    echo "### 校验"
    echo
    echo '```'
    echo "sha256: $SHA256"
    echo '```'
    echo
    echo "要求 macOS 14 或更新，Apple 芯片（arm64）。"
  } > "$notes"

  NOTES_FILE="$notes"
}

publish() {
  say "提交版本号"
  git add project.yml
  git commit -q -m "chore(release): $TARGET_VERSION"
  ok "$(git log --oneline -1)"

  say "打 tag 并推送"
  git tag -a "$TAG" -m "Silvics $TARGET_VERSION"
  git push origin HEAD --tags
  ok "$TAG"

  say "创建 GitHub Release"
  gh release create "$TAG" "$DMG_PATH" \
    --repo "$REPO" \
    --title "Silvics $TARGET_VERSION" \
    --notes-file "$NOTES_FILE" \
    --verify-tag
  ok "https://github.com/$REPO/releases/tag/$TAG"
}

rollback() {
  local version="$1" tag="$TAG_PREFIX$1"
  say "回滚 $version"
  gh release delete "$tag" --repo "$REPO" --yes 2>/dev/null && ok "已删 release" || warn "release 不存在"
  git push origin --delete "$tag" 2>/dev/null && ok "已删远端 tag" || warn "远端 tag 不存在"
  git tag -d "$tag" 2>/dev/null && ok "已删本地 tag" || warn "本地 tag 不存在"
  warn "版本号提交保留未回退，需要时手工 git revert"
}

# ---------- 入口 ----------

MODE="release"
TARGET_VERSION=""
DRY_RUN=0
RELEASE_SUMMARY="${RELEASE_SUMMARY:-}"

case "${1:-}" in
  ""|-h|--help)
    sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --check-upload)
    preflight; check_upload_channel; exit 0
    ;;
  --rollback)
    [ -n "${2:-}" ] || die "用法：scripts/release.sh --rollback <版本>"
    rollback "$2"; exit 0
    ;;
  *)
    TARGET_VERSION="$1"
    shift || true
    for arg in "$@"; do
      case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) die "不认识的参数：$arg" ;;
      esac
    done
    ;;
esac

[[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号要写成 x.y.z，收到：$TARGET_VERSION"
TAG="$TAG_PREFIX$TARGET_VERSION"

preflight
require_clean_tree
if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "tag $TAG 已存在。要重发先跑 scripts/release.sh --rollback $TARGET_VERSION"
fi

BUILD_NUMBER="$(next_build_number)"
say "目标版本 ${TARGET_VERSION}（构建号 ${BUILD_NUMBER}）"
write_version "$TARGET_VERSION" "$BUILD_NUMBER"
ok "已写入 project.yml（当前 $(project_version) / $(project_build)）"

build_app
verify_app
package_dmg
release_notes

if [ "$DRY_RUN" = "1" ]; then
  echo
  say "dry-run 完成，未提交、未打 tag、未上传"
  echo "  产物：$DMG_PATH"
  echo "  说明：$NOTES_FILE"
  echo "  还原版本号：git checkout -- project.yml"
  exit 0
fi

echo
say "发布会改动 GitHub 仓库 $REPO"
read -r -p "继续？[y/N] " confirm
[ "$confirm" = "y" ] || { warn "已取消"; echo "  还原版本号：git checkout -- project.yml"; exit 1; }

publish
echo
say "完成"
echo "  下载：https://github.com/$REPO/releases/latest"
echo "  sha256：$SHA256"
