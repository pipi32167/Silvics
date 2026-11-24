# 发布流程

版本号只由 `scripts/release.sh` 写进 `project.yml`。不要手改，也不要手打 tag。

## 版本策略

| 位 | 何时加 |
| --- | --- |
| major | 还不排期。数据格式不兼容时再说 |
| minor | 完成一个阶段（P4、P5…） |
| patch | 每次对外发布 |

起点 `0.1.0`。tag 形如 `v0.1.0`，与 `CFBundleShortVersionString` 一致。
`CFBundleVersion`（构建号）用 `git rev-list --count HEAD`，每次发布唯一，不用手管。

## 三条命令

```bash
# 1. 验证 GitHub 上传通道（可选，怀疑网络时用）
scripts/release.sh --check-upload

# 2. 先干跑：只构建 + 打包，不提交、不打 tag、不上传
scripts/release.sh 0.1.1 --dry-run

# 3. 正式发布（会二次确认）
scripts/release.sh 0.1.1
```

干跑完记得还原版本号：`git checkout -- project.yml`。

## 脚本做了什么

```text
预检（Xcode / xcodegen / gh / 工作区干净 / tag 不存在）
  → 写版本号 + 构建号到 project.yml
  → xcodegen generate
  → Release 构建（arm64）
  → 断言 Info.plist 版本
  → ad-hoc 签名 + codesign --verify --strict + xattr -cr
  → dist/dmg-root（App + Applications 符号链接）→ hdiutil UDZO
  → hdiutil verify + sha256
  → 生成 release notes（概述 + git log + 安装说明 + 校验和）
  → commit chore(release) → annotated tag → git push（SSH）
  → gh release create --verify-tag
```

产物：`dist/Silvics-<版本>.dmg`、`dist/release-notes.md`。`dist/` 不入库。

## 签名

没有 Apple 开发者证书，包里是 **ad-hoc 签名**（`codesign --sign -`），未公证。

后果：下载者首次打开会被 Gatekeeper 拦。安装说明写在 release notes 里：

1. 拖进「应用程序」。
2. Finder 里右键 App →「打开」→ 再点「打开」。
3. 或者先 `xattr -d com.apple.quarantine /Applications/Silvics.app`。

拿到 Developer ID 后，把脚本里 `codesign --sign -` 换成证书名，再加
`xcrun notarytool submit` 与 `xcrun stapler staple` 两步即可。

## 失败处理

| 现象 | 处理 |
| --- | --- |
| tag 已存在 | `scripts/release.sh --rollback <版本>` 后重发 |
| 发布到一半失败（release 建了一半） | 同上回滚，再重跑 |
| 上传 404 / 卡住 | 先 `--check-upload`；本机 `github.com` 的 HTTPS 不通，需要代理时设 `SILVICS_SPM_PROXY=http://127.0.0.1:7890` |
| 构建卡在 `Fetching from https://github.com` | 同上，设 `SILVICS_SPM_PROXY` |
| 想要中文概述 | `RELEASE_SUMMARY="一句话概述" scripts/release.sh 0.1.3` |

回滚只删 tag 与 release，不自动 revert 版本提交。需要时 `git revert`。

## 发布后自检

```bash
gh release view v0.1.0 --repo pipi32167/Silvics
hdiutil attach dist/Silvics-0.1.0.dmg      # 能看到 App 与 Applications 链接
codesign --verify --strict "/Volumes/Silvics/Silvics.app"
shasum -a 256 dist/Silvics-0.1.0.dmg       # 与 release notes 里的值对比
```
