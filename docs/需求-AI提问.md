# AI 提问 · 需求与设计（issue #45）

对应 [issue #45](https://github.com/pipi32167/Silvics/issues/45)。

## 术语

- **会话**（session）：一组按时间排列的提问与回答。按笔记 id 隔离。
- **上下文**（context）：一次请求里发给模型的材料。含系统提示词、当前笔记正文、引用、历史轮次。
- **引用**（quote）：用户在编辑器里选中并附到提问里的正文片段。
- **证据**（evidence）：应用抓取网页后抽出的正文。作为提问材料发给模型。
- **提示词**（prompt）：用户可复用的提问模板。分内置与自定义。
- **右栏**：主窗口最右侧面板。现在放反向链接、摘要、标签。

## 1. 目标

让用户在任意模块都能向 AI 提问。
AI 回答要带上当前笔记内容。
AI 能联网查资料。
AI 能基于用户选中的片段追问。
用户能管理常用提示词。

issue 标题写「剪藏」，正文写「任何模块」。本文按正文实现。剪藏是主要场景，笔记与日记同样可用。

## 2. 现状

| 能力 | 现状 | 缺口 |
| --- | --- | --- |
| 模型调用 | `ChatClient.complete` 已支持多轮 `messages`，三种协议族 | 固定 `temperature=0`；无流式；无取消 |
| 用途绑定 | `ProviderService.effective(.chat)` 可用，密钥在 Keychain | 新增用途不用改 |
| 右栏 | `ContextPanelView` 按模块渲染详情 | 没有提问入口 |
| 联网 | `ClipFetchService.fetch` + `ClipExtractor` 已能抓网页并抽正文 | 没接到 AI 请求 |
| 引用 | 编辑器用 `NSTextView`，`selectedRange()` 可取选区 | `AppState` 没有导出选区 |
| 提示词 | `ClipAIService` 里写死一句系统提示词 | 没有用户可配置项 |
| 会话 | `AppState` 没有消息状态 | 需要新增 |

结论：协议层和抓取层可复用。缺的是状态、上下文拼装、界面、设置。

## 3. 需求细化

### 3.1 维护 AI 的上下文

规则：

1. 每个笔记 id 一个会话。切换笔记切换会话。切回来恢复原会话。
2. 会话落 vault 文件。跨设备同步。切回来恢复原会话。
3. 自动上下文含四项：

   - 笔记标题
   - 笔记正文
   - 用户引用
   - 历史轮次
4. 正文按字符数截断。默认 8000 字。可选 0 / 4000 / 8000 / 20000。
5. 历史按轮次截断。默认 10 轮。超出时丢最早的轮次。系统提示词与引用永不丢。
6. 用户点「清空上下文」后写入清空标记。标记随会话同步。
7. 切换笔记前先 `flushPendingSave()`。上下文必须取已保存的正文。

截断顺序固定：先丢最早历史，再截正文。理由：引用与当前正文比旧对话更相关。

### 3.1.1 会话同步

会话落 vault，不落 sqlite。sqlite 只在运行时缓存当前会话。

文件位置：

- 笔记会话：`ai/<note-id>.jsonl`。
- 全局会话：`ai/_global.jsonl`。

每行一个 JSON 对象。格式叫 JSON Lines（JSONL）。一条消息一行。正文里的换行转义成 `\n`，所以一行不会断成多行。示例：

<!-- stc-lint: off -->
```jsonl
{"id":"UUID","at":1764000000000,"role":"user","content":"这段怎么理解","quote":{"noteID":"n123","noteTitle":"标题","text":"引用片段"}}
{"id":"UUID","at":1764000003000,"role":"assistant","content":"回答正文","model":"deepseek-chat","inputTokens":1200,"outputTokens":380}
```
<!-- stc-lint: on -->

消息 id 用 UUID。跨设备不重复。时间用 Unix 毫秒。

角色有三种。`user` 与 `assistant` 是对话。`clear` 是清空标记，只带 `id` 与 `at`。清空不删文件。理由：另一台的追加会让删掉的文件复活。

元数据跟着消息走。每条消息可带引用、证据、模型名、输入与输出 token。跨设备合并后元数据仍在。

三方合并写成纯函数，可单测：

```swift
merge(base: [AIMessage], local: [AIMessage], remote: [AIMessage]) -> [AIMessage]
```

先把三份 JSONL 逐行解析成消息数组。坏行跳过并记录。再做四步：

1. 按 `id` 去重。
2. 取 base 共有、本地独有、远端独有的并集。
3. 按 `at` 升序排。`at` 相同按 `id` 字典序排。
4. 找最新的清空标记。丢掉它之前的消息。

manifest 扩展 `conversations` 数组。每项含 `id`、`hash`、`updated`。schema 从 2 升到 3。旧 manifest 缺字段时补空数组。

导出时把 `ai/` 写进 vault，并更新 manifest。`ai/` 不进主列表、搜索、提及、引用解析。`verify()` 要检查会话文件哈希。删笔记时保留会话文件，留档。

同步走现有 `VaultSync.sync()`。每条消息写完原子写文件。下一次定时或手动同步带上。不另开 git 通道。

单会话上限 200 条消息或 200 KB。超出丢最早消息。引用存笔记 id、标题、片段。证据存 URL、标题、6000 字以内正文。密钥和完整网页正文不写会话文件。

会话随 vault 进 git。用户把 vault 推到公开仓库时，提问内容会公开。设置页加一行提示。

### 3.2 AI 联网查询

v1 只用本地抓取。外部联网服务不接。

流程：

1. 用户点「联网」，输入 URL。
2. 应用用 `ClipFetchService.fetch` 抓取。只接受 `http` / `https`，上限 5 MB，超时 15 秒。
3. 应用用 `ClipExtractor` 抽正文。超过 6000 字时取头尾。
4. 应用把证据标为不可信数据，附到本轮提问。
5. 模型基于证据回答。回答里给出来源 URL。

约束：

- 证据只进入当前一轮。不写入会话历史。
- 提示词要求忽略网页里的指令。
- 日志不写正文、URL 查询参数、密钥。
- 抓取失败时给中文原因。用户可删掉证据重发。

后续候选（不进 v1）：

- DeepSeek Web Tools：模型自己联网。工具调用从 2026-11-18 起不按次收费，只计模型 token。需要 `deepseek-flash`。
- Tavily：搜索与 Extract。每月 1000 credits，免信用卡。
- Jina Reader：`r.jina.ai/<url>` 免 key。内部用模型处理，图片由视觉语言模型（VLM）加说明。本机网络不通，未实测。
- DeepSeek Search / Fetch API：每 1000 次 0.75 美元，不是免费。
- Serper：搜索 2500 次一次性。
- Firecrawl：免费计划给月度 credits，约 1000 页。

pi agent 没有内置 web 工具。它的联网来自 MCP server 或 extension 注册的工具。Silvics 不嵌 pi，只借鉴「模型给工具参数 → 应用执行 → 结果回灌」的循环。

### 3.3 引用内容进行追问

规则：

1. 用户在编辑器选中文字，按 `⌘⇧Q`，选区成为引用。
2. 右栏提问框上方显示引用卡片。
   卡片含来源标题、原文片段、删除按钮。
3. 片段上限 500 字。超出取前 300 加后 200，中间标省略字数。
4. 一次提问最多带一条引用。新引用替换旧引用。
5. 请求里把引用放在当前正文之前，标明来源标题。
6. 回答里出现 `[[笔记标题]]` 时渲染成可点链接。点击跳转，不存在就按现有 `openTitle` 新建。

选区来自 `NSTextView.selectedRange()`。剪藏阅读器复用 `NoteEditorView`，所以三个模块取法一致。`AppState` 新增只读方法取选区；窗口里没有编辑器时返回空。

### 3.4 配置常用提示词

新增设置页「AI 提问」。字段：

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| 默认系统提示词 | 一段固定文本 | 每次请求都带上 |
| 常用提示词 | 4 条内置 | 可增删改，可恢复默认 |
| 正文字符上限 | 8000 | 0 / 4000 / 8000 / 20000 |
| 历史轮数 | 10 | 3 / 5 / 10 / 20 |

内置提示词：`总结一下`、`解释这段`、`列出关键结论`、`翻译成英文`。每条有 id、标题、正文。内置项可改正文，不可删除；恢复默认只还原内置项。

右栏提问框上方放提示词下拉。选中后把文本填进输入框，不清空已有输入，追加在末尾。

存储：`Core/AISettings.swift`，`Codable`，key `silvics.ai.settings`。缺字段补默认。`ProviderService.resetAll` 一并清空。

### 3.5 右栏形态

右栏顶部加分段控件：`详情` / `AI`。默认 `详情`。选择记入 `AISettings`，下次启动沿用。

`AI` 页自上而下：

1. 会话标题是当前笔记标题。
   没有选中笔记时，标题显示「全局提问」。
2. 消息列表：用户与 AI 交替。AI 回答可选中复制。
3. 引用卡片：仅选中文字后出现。
4. 证据卡片：仅抓取成功后出现。
5. 输入框：多行，回车发送，`⇧`+回车换行。
6. 底部按钮：联网、清空上下文、停止生成。

全局会话：没有选中笔记时使用固定 id `__global__`。正文上下文为空，其余规则不变。

窄窗口下右栏仍可达 200 px。布局按 200 px 设计，控件不依赖固定宽度。

## 4. 数据设计

新增纯 Swift 类型，放 `Core/`，不导入 SwiftUI 与 AppKit。

```swift
struct AIMessage: Equatable, Codable {
    var id: String                // UUID
    var at: Int64                 // Unix 毫秒
    var role: String              // user / assistant / clear
    var content: String = ""
    var quote: AIQuote? = nil
    var evidences: [AIEvidence] = []
    var model: String? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
}

struct AIQuote: Equatable, Codable {
    var noteID: String
    var noteTitle: String
    var text: String
}

struct AIEvidence: Equatable, Codable {
    var url: String
    var title: String
    var text: String
}

struct AISession {
    var id: String
    var messages: [AIMessage]
}

struct AIContextRequest {
    var systemPrompt: String
    var noteTitle: String
    var noteBody: String
    var quote: AIQuote?
    var evidences: [AIEvidence]
    var history: [AIMessage]
}
```

`AIContextBuilder` 负责拼 `messages`，并暴露纯函数供单测：

- `build(request:) -> [ChatMessage]`
- `trimHistory(_:rounds:) -> [AIMessage]`
- `truncateBody(_:limit:) -> String`
- `truncateQuote(_:) -> String`

`ChatClient.complete` 增加 `temperature` 参数，默认 0。AI 提问传 `AISettings.temperature`（固定 0.3，v1 不暴露）。剪藏整理不受影响。

## 5. 失败与边界

| 场景 | 行为 |
| --- | --- |
| 没配对话模型 | 输入框禁用，给「去设置 → 模型服务」链接文案 |
| 模型超时 | 停止生成，保留用户提问，允许重试 |
| 用户点停止 | 取消当前 `Task`，保留已收到的历史；无流式时丢弃本次回答 |
| 模型返回空 | 显示「模型没有返回正文」，不写历史 |
| 正文为空 | 不注入正文，其余上下文照常 |
| 引用超长 | 按 §3.3 截断 |
| 抓取非 HTML | 显示中文原因，不带证据发送 |
| 切换笔记时正在请求 | 取消请求，结果不写入新会话 |
| 重复点击发送 | 发送中禁用按钮 |

## 6. 测试

单测放 `Tests/SilvicsTests/AITests.swift`。全部用桩，不发真实网络，不碰真钥匙串。

| 用例 | 判据 |
| --- | --- |
| 历史截断 | 20 轮压到 10 轮，保留最近 10 条 |
| 正文截断 | 20000 字压到 8000，中间有省略标记 |
| 引用优先级 | 历史被裁光时引用仍在 |
| 证据不进历史 | 第二轮请求的 `messages` 里没有第一轮证据 |
| 提示词缺字段 | 解码后补默认值 |
| 恢复默认 | 内置项还原，自定义项清空 |
| 引用截断 | 800 字压到 500，取头 300 尾 200 |
| 空白正文 | 不插入空的正文段 |
| 多协议请求 | OpenAI / Anthropic / Gemini 都带上完整历史 |
| 失败降级 | 模型返回空时不写历史 |
| 搜索请求 | `count` 默认 5，`need_content` 为 `true`，错误映射成中文 |
| 会话三方合并 | 两边追加合到一起。消息 id 不重复，时间顺序正确 |
| 清空同步 | 清空标记之前的消息被丢掉，另一台的新消息保留 |
| 会话哈希 | manifest 能查出会话文件漂移 |
| JSONL 往返 | 含换行与中文的正文编码后仍是一行，解码内容不变 |
| 非法行 | 跳过坏行，其余消息照常解析 |
| 元数据保留 | 模型名、token、引用在跨设备合并后仍在 |

端到端截图覆盖以下场景：

- 空态
- 多轮对话
- 引用追问
- 联网证据
- 提示词设置
- 无模型
- 超时
- 长正文
- 200 px 窄右栏

## 7. 任务拆分

| 批次 | 内容 | 落地文件 |
| --- | --- | --- |
| 1 | `AISettings`、上下文拼装、JSONL 会话与三方合并、单测 | `Core/AISettings.swift`、`Core/AIContextBuilder.swift`、`Core/AIConversationStore.swift`、`Tests/AITests.swift` |
| 2 | `AppState` 会话与选区、发送与取消、本地抓取 | `App/AppState.swift` |
| 3 | 会话落 `ai/`、manifest schema 3、同步与校验接线 | `Core/VaultFormat.swift`、`Core/VaultSync.swift` |
| 4 | 右栏 AI 页、提示词设置页、快捷键与菜单 | `UI/AIChatPanelView.swift`、`UI/Settings/AISettingsPane.swift`、`UI/RootView.swift` |
| 5 | 截图验收、报告入库、发版 | `docs/acceptance/ai-chat-v*/` |

先写测试再写实现。新增 `.swift` 文件后重跑 `xcodegen generate`。

## 8. 已确认与待确认

已确认：

1. 联网用本地抓取。外部联网服务不进 v1。
2. 会话落 vault，跨设备同步。
3. 右栏用 `详情` / `AI` 两个 tab。
4. 引用快捷键用 `⌘⇧Q`。

待确认：

1. 会话放 `ai/*.jsonl` 并进 manifest 是否接受？manifest schema 从 2 升到 3。
2. 会话随 git 同步。vault 推到公开仓库时提问会公开。是否需要额外提示或加密？
