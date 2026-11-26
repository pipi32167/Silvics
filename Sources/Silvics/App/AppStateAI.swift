import AppKit
import Foundation

// MARK: - AI 提问

/// `AppState` 的 AI 提问部分：会话、选区引用、发送与取消、网页证据。
///
/// 会话落 `<vault>/ai/<note-id>.jsonl`，跟着 vault 同步。
/// 所有网络请求都在 `aiTask` 里跑，点「停止」直接取消。
@MainActor
extension AppState {

    /// 当前会话的 id。没有选中笔记时用全局会话。
    var aiSessionID: String { current?.id ?? AIConversation.globalID }

    /// 会话文件读写。
    var aiStore: AIConversationStore { AIConversationStore(vaultURL: repo.vaultURL) }

    /// 界面要显示的消息（去掉清空标记）。
    var aiVisibleMessages: [AIMessage] { AIConversation.visible(aiMessages) }

    /// 当前可用的对话模型。没配就是 nil。
    var aiProvider: (config: ProviderConfig, key: String)? { providerService.effective(.chat) }

    var aiUnavailableReason: String? {
        aiProvider == nil ? (providerService.unavailableReason(.chat) ?? "没有可用的对话模型") : nil
    }

    var aiCanSend: Bool { !aiIsSending && aiProvider != nil }

    /// 右栏当前页签。
    var aiPanel: AISettings.PanelTab { aiSettings.panel }

    // MARK: - 读取会话

    /// 从 vault 读当前会话。切换笔记时调用。
    func loadAIConversation() {
        let loaded = aiStore.load(noteID: aiSessionID)
        aiMessages = loaded.messages
        aiBadLineCount = loaded.badLines
        aiQuote = nil
        aiEvidences = []
        aiError = nil
    }

    /// 手动刷新（同步完成后、换 vault 后）。
    func reloadAIConversation() {
        guard !aiIsSending else { return }
        loadAIConversation()
    }

    // MARK: - 设置

    func updateAISettings(_ settings: AISettings) {
        aiSettings = settings.repaired()
        aiSettings.save()
    }

    func setAIPanel(_ tab: AISettings.PanelTab) {
        guard aiSettings.panel != tab else { return }
        var settings = aiSettings
        settings.panelTab = tab.rawValue
        updateAISettings(settings)
    }

    /// 恢复默认提示词：内置项还原，自定义项清空。
    func resetAIPrompts() {
        updateAISettings(AISettings.resetPrompts(aiSettings))
        statusMessage = "提示词已恢复默认。"
    }

    /// 选中一条常用提示词：追加到输入框末尾，不清掉已经写的内容。
    func applyAIPrompt(_ template: AIPromptTemplate) {
        let body = template.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let existing = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        aiInput = existing.isEmpty ? body : existing + "\n" + body
    }

    // MARK: - 引用

    /// 把编辑器里选中的一段存成引用。剪藏阅读器、笔记、日记都走这里。
    @discardableResult
    func captureQuoteFromEditor() -> Bool {
        guard let note = current else {
            statusMessage = "先选一条笔记，再在正文里选中一段。"
            return false
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let textView = Self.editorTextView(in: window.contentView!, matching: note.body)
        else {
            statusMessage = "没找到编辑区。"
            return false
        }
        let range = textView.selectedRange()
        guard range.length > 0 else {
            statusMessage = "先在正文里选中一段文字。"
            return false
        }
        let full = textView.string as NSString
        guard NSMaxRange(range) <= full.length else { return false }
        let text = full.substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "选中的是空白。"
            return false
        }
        aiQuote = AIQuote(noteID: note.id, noteTitle: note.title, text: text)
        setAIPanel(.ai)
        statusMessage = "已把选中的 \(text.count) 字带到提问里。"
        return true
    }

    func removeAIQuote() {
        aiQuote = nil
    }

    // MARK: - 网页证据

    /// 抓一个网页作为本轮材料。只支持 http / https，上限 5 MB。
    func addAIEvidence(url raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiEvidenceLoading = true
        aiError = nil
        defer { aiEvidenceLoading = false }

        switch await ClipFetchService.fetch(raw: trimmed, timeout: clipSettings.fetchTimeout) {
        case .failure(let error):
            aiError = "抓取失败：\(error.localizedDescription)"
        case .success(let page):
            do {
                let draft = try ClipIngest.draft(fromPage: page)
                let evidence = AIEvidence(
                    url: draft.url.isEmpty ? trimmed : draft.url,
                    title: draft.sourceTitle,
                    text: draft.body
                )
                guard !evidence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    aiError = "这个网页没有可用的正文。"
                    return
                }
                aiEvidences.append(evidence)
                setAIPanel(.ai)
            } catch {
                aiError = "正文抽取失败：\(error.localizedDescription)"
            }
        }
    }

    func removeAIEvidence(at index: Int) {
        guard aiEvidences.indices.contains(index) else { return }
        aiEvidences.remove(at: index)
    }

    // MARK: - 发送

    /// 发送当前输入框里的提问。
    func sendAIQuestion() {
        let text = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard aiProvider != nil else {
            aiError = aiUnavailableReason
            return
        }
        guard !aiIsSending else { return }
        // 先把本轮材料取出来，再清输入框与证据卡片。
        let evidences = aiEvidences
        let quote = aiQuote
        aiInput = ""
        aiEvidences = []
        startAIRequest(text: text, quote: quote, evidences: evidences, appendUser: true)
    }

    /// 重发上一条提问：不再追加一条新的用户消息。
    func retryAILastQuestion() {
        guard !aiIsSending, aiProvider != nil else { return }
        guard let last = aiVisibleMessages.last, last.isUser else { return }
        startAIRequest(
            text: last.content,
            quote: last.quote,
            evidences: last.evidences,
            appendUser: false
        )
    }

    /// 点「停止」：取消在跑的请求。已经存进会话的用户提问保留。
    func cancelAIRequest() {
        aiTask?.cancel()
        aiTask = nil
        aiIsSending = false
        statusMessage = "已停止生成。"
    }

    /// 起一个请求任务。取消就走 `aiTask.cancel()`。
    private func startAIRequest(
        text: String,
        quote: AIQuote?,
        evidences: [AIEvidence],
        appendUser: Bool
    ) {
        aiIsSending = true
        aiError = nil
        aiTask?.cancel()
        aiTask = Task { [weak self] in
            await self?.executeAIRequest(
                text: text, quote: quote, evidences: evidences, appendUser: appendUser
            )
        }
    }

    /// 真正发请求。先用已有历史拼上下文，成功后把回答追加进会话。
    private func executeAIRequest(
        text: String,
        quote: AIQuote?,
        evidences: [AIEvidence],
        appendUser: Bool
    ) async {
        guard let provider = aiProvider else {
            aiError = aiUnavailableReason
            aiIsSending = false
            return
        }
        // 上下文必须取已保存的正文，否则会漏掉刚敲的字。
        flushPendingSave()

        let sessionID = aiSessionID
        var history = aiVisibleMessages
        if appendUser {
            let message = AIMessage(
                id: UUID().uuidString, at: AIMessage.now(),
                role: AIMessage.roleUser, content: text, quote: quote, evidences: evidences
            )
            _ = try? aiStore.append(message, noteID: sessionID)
            aiMessages = aiStore.load(noteID: sessionID).messages
            history = AIConversation.visible(aiMessages).filter { $0.id != message.id }
        }

        let request = AIContextRequest(
            systemPrompt: aiSettings.systemPrompt,
            noteTitle: current?.title ?? "",
            noteBody: current?.body ?? "",
            quote: quote,
            evidences: evidences,
            history: history,
            question: text,
            bodyLimit: aiSettings.bodyLimit,
            historyRounds: aiSettings.historyRounds
        )

        let result = await ChatClient.complete(
            config: provider.config,
            key: provider.key,
            messages: AIContextBuilder.build(request),
            maxTokens: 1600,
            temperature: 0.3
        )

        // 被取消时不写盘，但把已经存进去的用户提问重新读回来。
        if Task.isCancelled {
            loadConversationFromDisk(sessionID: sessionID)
            if aiIsSending { aiIsSending = false; aiTask = nil }
            return
        }
        finishAIRequest(result, sessionID: sessionID, config: provider.config)
    }

    private func finishAIRequest(
        _ result: Result<String, LLMError>,
        sessionID: String,
        config: ProviderConfig
    ) {
        aiIsSending = false
        aiTask = nil

        switch result {
        case .failure(let error):
            aiError = error.message
            loadConversationFromDisk(sessionID: sessionID)
        case .success(let text):
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                aiError = "模型没有返回正文。"
                loadConversationFromDisk(sessionID: sessionID)
                return
            }
            let message = AIMessage(
                id: UUID().uuidString, at: AIMessage.now(), role: AIMessage.roleAssistant,
                content: answer, model: config.chatModel
            )
            _ = try? aiStore.append(message, noteID: sessionID)
            loadConversationFromDisk(sessionID: sessionID)
            aiQuote = nil
        }
    }

    /// 只刷新从磁盘读到的东西，不动本轮引用。
    private func loadConversationFromDisk(sessionID: String) {
        guard sessionID == aiSessionID else { return }
        let loaded = aiStore.load(noteID: sessionID)
        aiMessages = loaded.messages
        aiBadLineCount = loaded.badLines
    }

    // MARK: - 清空

    /// 清空当前会话：写一条清空标记，不删文件。
    func clearAIConversation() {
        guard !aiIsSending else {
            statusMessage = "先生成结束或点停止，再清空。"
            return
        }
        do {
            aiMessages = try aiStore.clear(noteID: aiSessionID)
            aiQuote = nil
            aiEvidences = []
            aiError = nil
            statusMessage = "已清空当前会话的上下文。"
        } catch {
            statusMessage = "清空失败：\(error.localizedDescription)"
        }
    }
}
