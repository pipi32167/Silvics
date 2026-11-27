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

## 发版前：先合并到 main

发版脚本在哪个分支跑，就把 `HEAD` 推到**那个分支**。所以顺序固定：

1. 功能分支提 PR，合并进 `main`。
2. 在 `main` 的干净工作区发版（不要在功能分支或 worktree 里直接发）。

在功能分支上跑会得到「tag 有了、main 没有」的状态，事后要手工补 `git push origin <分支>:main`。

## 四条命令

```bash
# 1. 验证 GitHub 上传通道（可选，怀疑网络时用）
scripts/release.sh --check-upload

# 2. 先干跑：跑单测 + 构建 + 打包，不提交、不打 tag、不上传
scripts/release.sh 0.1.1 --dry-run

# 3. 正式发布（跑单测 → 构建 → 打包 → 二次确认）
scripts/release.sh 0.1.1

# 4. 确认这次只动打包相关的东西，跳过单测门禁（发版记录里写原因）
scripts/release.sh 0.1.1 --skip-tests
```

干跑完记得还原版本号：`git checkout -- project.yml`。

单测门禁会跑 `xcodebuild test`（Debug、跳过签名），任一条红就停。
日志在 `${TMPDIR:-/tmp}/silvics-release-test.log`。

## ```text
预检（Xcode / xcodegen / gh / 工作区干净 / tag 不存在）
  → 跑单测（任何一条红就停；--skip-tests 可跳过）
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

## 验收报告归档

每次验收的产物放 `docs/acceptance/<主题>-v<版本>/`，版本号与该次发布一致：

```text
docs/acceptance/ime-render-v0.8.1/report.md
docs/acceptance/ime-render-v0.8.1/artifacts/
```

主题用小写英文短横线，跟分支名里的关键字对齐。先按功能命名再改版本号，
会让「这个报告对应哪个包」需要翻 git 历史才能回答。

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
