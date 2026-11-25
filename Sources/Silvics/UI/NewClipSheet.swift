import AppKit
import SwiftUI

/// 新建剪藏。三态：输入 → 抓取/抽取/整理 → 预览。
///
/// URL、粘贴正文、文件三个入口。整理失败不阻塞保存：正文先落库，标「待整理」。
struct NewClipSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case input
        case working(String)
        case preview
    }

    @State private var phase: Phase = .input
    @State private var urlText: String = ""
    @State private var isPasteMode = false
    @State private var pastedBody: String = ""
    @State private var pastedTitle: String = ""
    @State private var pickedFile: URL?
    @State private var draft: ClipDraft?
    @State private var warnings: [String] = []
    @State private var errorText: String?
    @State private var duplicateHint: String?
    @State private var previewTitle: String = ""
    @State private var previewSummary: String = ""
    @State private var previewTags: [String] = []
    @State private var tagInput: String = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch phase {
            case .input:
                inputForm
            case .working(let step):
                workingView(step)
            case .preview:
                previewForm
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(18)
        .frame(width: 620, height: phase == .input ? 380 : 560, alignment: .topLeading)
        .onAppear {
            #if DEBUG
            applyDebugStateIfRequested()
            #endif
            if let text = NSPasteboard.general.string(forType: .string),
               ClipURL.normalized(text) != nil, urlText.isEmpty {
                urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    #if DEBUG
    /// 仅取证：把面板直接放在预览或错误态，用来截稳定图。
    /// 走的是和真实流程一样的 `presentPreview` / 错误文案，不伪造界面。
    private func applyDebugStateIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let mode = env["SILVICS_CLIP_STATE"] {
            switch mode {
            case "preview":
                var value = ClipDraft(
                    url: "https://sspai.com/post/example",
                    title: "写作工具如何影响写作频率",
                    sourceTitle: "写作工具如何影响写作频率",
                    site: "少数派",
                    author: "张三",
                    published: "2026-11-20",
                    body: String(repeating: "工具的手感决定写作频率。启动慢、光标跳、预览延迟，都会让人少写一段。\n\n", count: 4)
                )
                value.summary = "工具的手感直接决定写作频率。启动慢、光标跳、预览延迟都会让人少写一段；输入即渲染、没有保存按钮的工具更让人愿意随手记。这不是审美问题，是摩擦成本问题。"
                value.tags = ["学习方法", "笔记方法"]
                presentPreview(value)
            case "error":
                errorText = ClipFetchError.http(403).errorDescription
            default:
                break
            }
        }
    }
    #endif

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("新建剪藏")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if app.clipProvider() == nil {
                Label("未配置模型，只能手填摘要", systemImage: "sparkles.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 输入

    private var inputForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $isPasteMode) {
                Text("网址").tag(false)
                Text("粘贴正文").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if isPasteMode {
                TextField("标题（可空，留空由模型或正文首行决定）", text: $pastedTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                TextEditor(text: $pastedBody)
                    .font(.system(size: 12))
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            } else {
                TextField("https://…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { Task { await ingestURL() } }
                HStack(spacing: 8) {
                    Button("从剪贴板读取") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    Button("选择文件…") { pickFile() }
                    if let pickedFile {
                        Text(pickedFile.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)

                Text("也可以把文件或网址拖到这里。支持 md、txt、html。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            if let duplicateHint {
                Label(duplicateHint, systemImage: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 进行中

    private func workingView(_ step: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text(step)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("抓取 → 抽取 → 整理。整理失败也会先保存正文。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 预览

    private var previewForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("标题", text: $previewTitle)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium))

            VStack(alignment: .leading, spacing: 5) {
                Text("摘要")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                TextEditor(text: $previewSummary)
                    .font(.system(size: 12))
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("标签")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if previewTags.isEmpty {
                    Text("没有标签")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(previewTags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text("#\(tag)")
                                    .font(.system(size: 11))
                                Button {
                                    previewTags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField("加标签，回车确认", text: $tagInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { addTag() }
                    Button("添加") { addTag() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .disabled(ClipTagPolicy.sanitize(tagInput) == nil)
                }
            }

            if let draft {
                HStack(spacing: 10) {
                    if let site = optional(draft.site) { Text(site) }
                    if let author = optional(draft.author) { Text(author) }
                    Text("\(draft.body.count) 字")
                    Spacer()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "info.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            switch phase {
            case .input:
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("抓取并整理") {
                    Task {
                        if isPasteMode { await ingestPaste() } else { await ingestURL() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canIngest)
            case .working:
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .preview:
                Button("返回") { phase = .input }
                Button("仅保存正文") { save(useAI: false) }
                Button("保存") { save(useAI: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(previewTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private var canIngest: Bool {
        if isPasteMode {
            return !pastedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if pickedFile != nil { return true }
        return ClipURL.normalized(urlText) != nil
    }

    // MARK: - 流程

    private func ingestURL() async {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if let existing = app.existingClip(forURL: raw) {
            duplicateHint = "这个地址已经剪藏过：《\(existing.title)》"
        }
        phase = .working("正在抓取网页…")
        errorText = nil
        let settings = app.clipSettings
        switch await ClipFetchService.fetch(raw: raw, timeout: settings.fetchTimeout) {
        case .failure(let error):
            errorText = error.errorDescription
            phase = .input
        case .success(let page):
            do {
                phase = .working("正在抽取正文…")
                var value = try ClipIngest.draft(fromPage: page)
                if let warning = ClipIngest.shortBodyWarning(value.body) {
                    warnings.append(warning)
                }
                value = await polish(value, settings: settings)
                presentPreview(value)
            } catch {
                errorText = error.localizedDescription
                phase = .input
            }
        }
    }

    private func ingestPaste() async {
        do {
            var value = try ClipIngest.draft(fromText: pastedBody, title: pastedTitle)
            if let existing = app.existingClip(forBody: value.body) {
                warnings.append("内容与已剪藏的《\(existing.title)》相同，仍然可以再存一份。")
            }
            phase = .working("正在整理…")
            value = await polish(value, settings: app.clipSettings)
            presentPreview(value)
        } catch {
            errorText = error.localizedDescription
            phase = .input
        }
    }

    private func ingestFile() async {
        guard let pickedFile else { return }
        do {
            var value = try ClipIngest.draft(fromFile: pickedFile)
            if let existing = app.existingClip(forBody: value.body) {
                warnings.append("内容与已剪藏的《\(existing.title)》相同，仍然可以再存一份。")
            }
            phase = .working("正在整理…")
            value = await polish(value, settings: app.clipSettings)
            presentPreview(value)
        } catch {
            errorText = error.localizedDescription
            phase = .input
        }
    }

    /// 调模型并落到最终草稿。模型不可用或失败时保留正文，标待整理。
    private func polish(_ draft: ClipDraft, settings: ClipSettings) async -> ClipDraft {
        var value = draft
        var suggestion: ClipSuggestion?
        var aiWarnings: [String] = []

        if settings.autoSummarize, let provider = app.clipProvider() {
            phase = .working("正在整理标题、摘要与标签…")
            let request = ClipAIRequest(
                sourceTitle: draft.sourceTitle,
                site: draft.site,
                body: draft.body,
                existingTags: app.clipTagCandidates(),
                summaryLimit: settings.summaryLimit,
                tagCount: settings.targetTagCount,
                titleStrategy: settings.titleStrategy
            )
            switch await ClipAIService.run(config: provider.config, key: provider.key, request: request) {
            case .success(let result):
                suggestion = result
            case .failure(let error):
                aiWarnings.append("整理失败：\(error.message)。正文仍可保存。")
            }
        } else if settings.autoSummarize {
            aiWarnings.append("未配置模型，正文先保存，摘要可稍后补。")
        }

        let finalized = ClipAIService.finalize(
            draft: value,
            suggestion: suggestion,
            settings: settings,
            existingTags: app.clipTagCandidates(),
            providerAvailable: app.clipProvider() != nil,
            isTaken: { app.clipTitleTaken($0) }
        )
        value = finalized.draft
        warnings += aiWarnings + finalized.warnings
        return value
    }

    private func presentPreview(_ draft: ClipDraft) {
        self.draft = draft
        previewTitle = draft.title
        previewSummary = draft.summary
        previewTags = draft.tags
        phase = .preview
    }

    private func save(useAI: Bool) {
        guard var draft else { return }
        isSaving = true
        draft.title = previewTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.summary = useAI ? previewSummary : ""
        draft.tags = useAI ? previewTags : []
        if !useAI { draft.aiState = .pending }
        do {
            _ = try app.saveClip(draft)
            dismiss()
        } catch let error as ClipError {
            if case .duplicateURL(let noteId, _) = error {
                errorText = "已经剪藏过这一篇。"
                app.selectClipScope(.clipAll)
                app.openClip(id: noteId)
                dismiss()
            } else {
                errorText = error.errorDescription
            }
        } catch {
            errorText = error.localizedDescription
        }
        isSaving = false
    }

    private func addTag() {
        guard let clean = ClipTagPolicy.sanitize(tagInput) else { return }
        if !previewTags.contains(where: { ClipTagPolicy.key($0) == ClipTagPolicy.key(clean) }) {
            previewTags.append(clean)
        }
        tagInput = ""
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .html, .init(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedFile = url
        isPasteMode = false
        Task { await ingestFile() }
    }

    private func optional(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }
}
