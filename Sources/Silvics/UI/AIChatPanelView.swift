import SwiftUI

/// 右栏「AI」页：会话、引用卡片、网页证据、输入框。
///
/// 布局按 200 px 宽设计。窄窗口下右栏最小就是这个宽度，
/// 所以所有控件都是纵向堆叠，不靠固定宽度对齐。
struct AIChatPanelView: View {
    @EnvironmentObject private var app: AppState

    @State private var evidenceURL = ""
    @State private var isShowingEvidenceField = false

    var body: some View {
        VStack(spacing: 0) {
            sessionHeader
            Divider()
            messageList
            composer
        }
    }

    // MARK: - 标题

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(app.current?.title ?? "全局提问")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if !app.aiVisibleMessages.isEmpty {
                    Button {
                        app.clearAIConversation()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("清空当前会话的上下文。写一条清空标记，随同步带走。")
                    .accessibilityIdentifier("ai-clear")
                }
            }
            HStack(spacing: 4) {
                if app.current == nil {
                    Text("没有选中笔记，正文上下文为空")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(app.aiVisibleMessages.count) 条消息")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if app.aiBadLineCount > 0 {
                    Text("\(app.aiBadLineCount) 行无法解析")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if app.aiVisibleMessages.isEmpty {
                        emptyHint
                    }
                    ForEach(app.aiVisibleMessages) { message in
                        bubble(message).id(message.id)
                    }
                    if let error = app.aiError {
                        errorBanner(error)
                    }
                    if app.aiIsSending {
                        sendingRow.id("ai-sending")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: app.aiVisibleMessages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: app.aiIsSending) { _, sending in
                if sending { scrollToBottom(proxy) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = app.aiVisibleMessages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(app.aiIsSending ? "ai-sending" : last.id, anchor: .bottom)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(app.current == nil ? "全局提问" : "就这一篇提问")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("正文会自动带上。在编辑器里选中一段按 ⌘⇧Q 可以只追问那一段。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func bubble(_ message: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(message.isUser ? "你" : "AI")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(message.isUser ? Color.secondary : Color.accentColor)
                Spacer(minLength: 0)
                if let model = message.model, !model.isEmpty {
                    Text(model)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }
            Text(message.content)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let quote = message.quote, !quote.text.isEmpty {
                quoteRow(quote)
            }
            ForEach(Array(message.evidences.enumerated()), id: \.offset) { _, evidence in
                evidenceRow(evidence)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(message.isUser ? Color.primary.opacity(0.05) : Color.accentColor.opacity(0.07))
        )
    }

    private func quoteRow(_ quote: AIQuote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("引用 · \(quote.noteTitle)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(quote.text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func evidenceRow(_ evidence: AIEvidence) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(evidence.title.isEmpty ? evidence.url : evidence.title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(evidence.url)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.orange.opacity(0.09))
        )
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if app.aiVisibleMessages.last?.isUser == true {
                Button("重试") { app.retryAILastQuestion() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var sendingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("正在生成…")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("停止") { app.cancelAIRequest() }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
        }
        .padding(.vertical, 4)
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()

            if let quote = app.aiQuote {
                activeQuoteCard(quote)
            }
            if !app.aiEvidences.isEmpty {
                activeEvidenceCards
            }
            if app.aiProvider == nil {
                providerHint
            }

            promptMenu

            TextEditor(text: $app.aiInput)
                .font(.system(size: 11.5))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 52, maxHeight: 120)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .accessibilityIdentifier("ai-input")

            HStack(spacing: 6) {
                Button {
                    isShowingEvidenceField.toggle()
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("抓一个网页作为本轮材料")
                .accessibilityIdentifier("ai-evidence-toggle")

                if app.aiEvidenceLoading {
                    ProgressView().controlSize(.mini)
                }

                Spacer(minLength: 0)

                if app.aiIsSending {
                    Button("停止") { app.cancelAIRequest() }
                        .font(.system(size: 11))
                } else {
                    Button("发送") { app.sendAIQuestion() }
                        .font(.system(size: 11))
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(!app.aiCanSend || app.aiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ai-send")
                }
            }

            if isShowingEvidenceField {
                evidenceField
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 10)
    }

    private func activeQuoteCard(_ quote: AIQuote) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "text.quote")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("引用 · \(quote.noteTitle)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(quote.text)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                app.removeAIQuote()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("去掉引用")
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private var activeEvidenceCards: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(app.aiEvidences.enumerated()), id: \.offset) { index, evidence in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(evidence.title.isEmpty ? evidence.url : evidence.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        app.removeAIEvidence(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }

    private var providerHint: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text("还没有可用的对话模型：\(app.aiUnavailableReason ?? "未配置")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var promptMenu: some View {
        Menu {
            ForEach(app.aiSettings.prompts) { template in
                Button(template.title) { app.applyAIPrompt(template) }
            }
            Divider()
            Button("编辑常用提示词…") {
                SettingsWindowController.show(app: app, tab: .ai)
            }
        } label: {
            Label("提示词", systemImage: "text.badge.plus")
                .font(.system(size: 10.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选一条常用提示词，追加到输入框")
        .accessibilityIdentifier("ai-prompt-menu")
    }

    private var evidenceField: some View {
        HStack(spacing: 5) {
            TextField("https://…", text: $evidenceURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5))
                .onSubmit { loadEvidence() }
            Button("抓取") { loadEvidence() }
                .font(.system(size: 10))
                .disabled(evidenceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || app.aiEvidenceLoading)
        }
    }

    private func loadEvidence() {
        let raw = evidenceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        evidenceURL = ""
        isShowingEvidenceField = false
        Task { await app.addAIEvidence(url: raw) }
    }
}
