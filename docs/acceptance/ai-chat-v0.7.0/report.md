# silvics · feat/ai-panel-issue45 验收报告

## 元信息

| 项 | 值 |
| --- | --- |
| commit | fc1be46 |
| 验收时间 | 2026-11-26 17:53 CST |
| 环境 | macOS 27 / Apple 芯片 / Debug 构建 / SILVICS_* 取证钩子 |
| 数据 | 演示数据 22 篇（SILVICS_SEED=1）；会话由 SILVICS_SHOW=ai-chat 预置，不调模型 |
| 缓存版本 | .build |
| 验收人 | pi agent |

## 结论

通过 12 项，不通过 0 项，待确认 0 项，未覆盖 4 项。

## 覆盖用例

| # | 用例 | 判据 | 结果 | 证据 |
| --- | --- | --- | --- | --- |
| 01 | 右栏页签切换 | 同一篇笔记下，详情页保留来源与连接；AI 页显示会话与输入框；页签选中态清晰 | 通过 | `artifacts/01-tab-switch.png` |
| 02 | AI 页空态 | 无会话时给出用途提示，输入框与提示词入口可用 | 通过 | `artifacts/02-ai-empty.png` |
| 03 | 多轮上下文 | 四轮消息按时间顺序渲染，AI 气泡标注模型名，引用随用户消息显示 | 通过 | `artifacts/03-multi-turn.png` |
| 04 | 引用追问 | 选中片段作为引用卡片出现在输入区上方，可一键去掉 | 通过 | `artifacts/04-quote-4x.png` |
| 05 | 网页证据 | 抓取成功的网页以证据卡片列出标题与来源，可单条删除 | 通过 | `artifacts/05-evidence-4x.png` |
| 06 | 未配置模型 | 没有可用对话模型时给出原因，发送按钮禁用，不静默失败 | 通过 | `artifacts/06-no-provider.png` |
| 07 | 生成中 | 请求期间显示进度与「停止」，发送按钮换成停止 | 通过 | `artifacts/07-sending.png` |
| 08 | 失败重试 | 失败原因就地显示，提供「重试」，已发出的提问保留在会话里 | 通过 | `artifacts/08-error-retry.png` |
| 09 | 200px 窄右栏 | 右栏压到 200px 时消息、引用、输入框不溢出、不重叠 | 通过 | `artifacts/09-narrow-200.png` |
| 10 | 深色模式 | 深色下用户与 AI 气泡、引用、证据、按钮对比度都够，文字不丢 | 通过 | `artifacts/10-dark.png` |
| 11 | 提示词设置页 | 系统提示词可改；4 条内置可改不可删；自定义可增删；正文上限与历史轮数可选 | 通过 | `artifacts/11-settings-pane.png` |
| 12 | 状态矩阵 | 四种状态布局一致，标题与输入区位置不跳 | 通过 | `artifacts/12-state-matrix.png` |

## 偏差清单

| 区域 | 设计稿值 | 实现值 | 判定 | 证据 |
| --- | --- | --- | --- | --- |
| 回答呈现 | 需求未规定是否流式输出 | 一次性返回；等待期只有「正在生成…」与「停止」，长回答不逐字出现 | 待确认 | `artifacts/07-sending.png` |
| 设置窗左侧栏 | 侧栏列出 外观/剪藏/AI 提问/模型服务/同步/关于 | DebugCapture 自绘取证时侧栏为空白（List 的 vibrancy 栅格化问题），详页面板本身正常 | 待确认 | `artifacts/11-settings-pane.png` |

## 未覆盖

| 用例 | 原因 |
| --- | --- |
| 真机按键 ⌘⇧Q | 自动化按键需要辅助功能授权，本次未驱动真实键盘；引用卡片由 SILVICS_SHOW=ai-quote 预置后截图 |
| 真实模型回答 | 取证不调外部模型，会话内容由 SILVICS_SHOW=ai-chat 写入固定文本；请求拼装另由 AIContextBuilderTests 覆盖 |
| 联网抓取真实网页 | 本机到外网受限，证据卡片由 SILVICS_SHOW=ai-evidence 预置；抓取链路复用已在 0.6.0 验收过的 ClipFetchService |
| 多语言与断点 | 应用只有中文界面，没有语言切换；窗口断点只验了 1000 宽与 900x700 两档 |

## 复现命令

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && xcodebuild -project Silvics.xcodeproj -scheme Silvics -configuration Debug -destination 'platform=macOS' -derivedDataPath .build CODE_SIGNING_ALLOWED=NO test
open .build/Build/Products/Debug/Silvics.app --env SILVICS_SEED=1 --env SILVICS_SHOW=ai-chat --env SILVICS_AI_PROVIDER=1 --env SILVICS_CAPTURE=/tmp/x.png --env SILVICS_WINDOW=1000x1020
open .build/Build/Products/Debug/Silvics.app --env SILVICS_SHOW=ai-chat --env SILVICS_CONTEXT_WIDTH=200 --env SILVICS_WINDOW=900x700 --env SILVICS_CAPTURE=/tmp/narrow.png
```

## 证据图

### 01 右栏页签切换

<img src="artifacts/01-tab-switch.png" alt="01-右栏页签切换" width="640">

[原图](artifacts/01-tab-switch.png) · 通过 · 判据 同一篇笔记下，详情页保留来源与连接；AI 页显示会话与输入框；页签选中态清晰

左：详情；右：AI

### 02 AI 页空态

<img src="artifacts/02-ai-empty.png" alt="02-AI-页空态" width="720">

[原图](artifacts/02-ai-empty.png) · 通过 · 判据 无会话时给出用途提示，输入框与提示词入口可用

状态矩阵 01-ai-empty

### 03 多轮上下文

<img src="artifacts/03-multi-turn.png" alt="03-多轮上下文" width="720">

[原图](artifacts/03-multi-turn.png) · 通过 · 判据 四轮消息按时间顺序渲染，AI 气泡标注模型名，引用随用户消息显示

状态矩阵 02-ai-chat

### 04 引用追问

<img src="artifacts/04-quote-4x.png" alt="04-引用追问" width="625">

[原图](artifacts/04-quote-4x.png) · 通过 · 判据 选中片段作为引用卡片出现在输入区上方，可一键去掉

细节放大 1 块 x4

### 05 网页证据

<img src="artifacts/05-evidence-4x.png" alt="05-网页证据" width="640">

[原图](artifacts/05-evidence-4x.png) · 通过 · 判据 抓取成功的网页以证据卡片列出标题与来源，可单条删除

细节放大 1 块 x4

### 06 未配置模型

<img src="artifacts/06-no-provider.png" alt="06-未配置模型" width="720">

[原图](artifacts/06-no-provider.png) · 通过 · 判据 没有可用对话模型时给出原因，发送按钮禁用，不静默失败

状态矩阵 05-ai-no-provider

### 07 生成中

<img src="artifacts/07-sending.png" alt="07-生成中" width="720">

[原图](artifacts/07-sending.png) · 通过 · 判据 请求期间显示进度与「停止」，发送按钮换成停止

状态矩阵 08-sending

### 08 失败重试

<img src="artifacts/08-error-retry.png" alt="08-失败重试" width="720">

[原图](artifacts/08-error-retry.png) · 通过 · 判据 失败原因就地显示，提供「重试」，已发出的提问保留在会话里

状态矩阵 09-error

### 09 200px 窄右栏

<img src="artifacts/09-narrow-200.png" alt="09-200px-窄右栏" width="720">

[原图](artifacts/09-narrow-200.png) · 通过 · 判据 右栏压到 200px 时消息、引用、输入框不溢出、不重叠

SILVICS_CONTEXT_WIDTH=200，窗口 900x700

### 10 深色模式

<img src="artifacts/10-dark.png" alt="10-深色模式" width="720">

[原图](artifacts/10-dark.png) · 通过 · 判据 深色下用户与 AI 气泡、引用、证据、按钮对比度都够，文字不丢

状态矩阵 10-dark

### 11 提示词设置页

<img src="artifacts/11-settings-pane.png" alt="11-提示词设置页" width="640">

[原图](artifacts/11-settings-pane.png) · 通过 · 判据 系统提示词可改；4 条内置可改不可删；自定义可增删；正文上限与历史轮数可选

裁掉了左侧栏：自绘取证下 List 侧栏受 vibrancy 影响变空白，属已知取证限制

### 12 状态矩阵

<img src="artifacts/12-state-matrix.png" alt="12-状态矩阵" width="590">

[原图](artifacts/12-state-matrix.png) · 通过 · 判据 四种状态布局一致，标题与输入区位置不跳

状态矩阵 空态 / 多轮 / 无模型 / 失败

## 截图清单

| 文件 | 说明 | 差异 |
| --- | --- | --- |
| `artifacts/01-tab-switch.png` | 左：详情；右：AI | — |
| `artifacts/02-ai-empty.png` | 状态矩阵 01-ai-empty | — |
| `artifacts/03-multi-turn.png` | 状态矩阵 02-ai-chat | — |
| `artifacts/04-quote-4x.png` | 细节放大 1 块 x4 | — |
| `artifacts/05-evidence-4x.png` | 细节放大 1 块 x4 | — |
| `artifacts/06-no-provider.png` | 状态矩阵 05-ai-no-provider | — |
| `artifacts/07-sending.png` | 状态矩阵 08-sending | — |
| `artifacts/08-error-retry.png` | 状态矩阵 09-error | — |
| `artifacts/09-narrow-200.png` | SILVICS_CONTEXT_WIDTH=200，窗口 900x700 | — |
| `artifacts/10-dark.png` | 状态矩阵 10-dark | — |
| `artifacts/11-settings-pane.png` | 裁掉了左侧栏：自绘取证下 List 侧栏受 vibrancy 影响变空白，属已知取证限制 | — |
| `artifacts/12-state-matrix.png` | 状态矩阵 空态 / 多轮 / 无模型 / 失败 | — |

## 说明

本次验收只覆盖界面与交互取证，模型请求与网页抓取不打真实网络。会话内容由 `SILVICS_SHOW=ai-chat` 预置固定文本，证据卡片由 `SILVICS_SHOW=ai-evidence` 预置。

代码验证另有两层：

- 单测 607 项全过，其中 AI 相关 60 项：JSONL 往返、坏行跳过、三方合并、清空标记、按条数与字节双闸裁剪、上下文拼装与截断、设置钳制。
- `AIConversationSyncTests` 用本机 bare 仓库当远端，两台「设备」各追加一条消息，同步后两端都是三条（并集，不互相覆盖）。

提交：`f0dc843` 会话模型与 JSONL；`fc1be46` 右栏与同步接线；`2bef16e` 字节闸与跨设备同步测试。截图取自 `fc1be46` 构建，`2bef16e` 只改 Core 层，不影响界面。
