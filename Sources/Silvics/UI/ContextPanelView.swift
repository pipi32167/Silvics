import AppKit
import SwiftUI

/// 右侧上下文面板：反向链接、出链、悬空目标。
/// 反向链接带原文上下文片段——这是 Matuschak 站点的做法，比纯标题列表有用。
struct ContextPanelView: View {
    @EnvironmentObject private var app: AppState

    @State private var summaryDraft: String = ""
    @State private var tagInput: String = ""
    @State private var summarySaveTask: Task<Void, Never>?
    @State private var isConfirmingDelete = false
    @State private var isSummarizing = false

    private var clipNote: Note? {
        guard let note = app.current, note.type == NoteTypes.clipID else { return nil }
        return note
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if app.aiPanel == .ai {
                AIChatPanelView()
            } else {
                detailsBody
            }
        }
        .background(Tokens.panel)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.panel, style: .continuous)
                .strokeBorder(Tokens.hair, lineWidth: 1)
        )
        .shadow(color: .black.opacity(Tokens.isDark ? 0.28 : 0.05), radius: 9, y: 3)
        .padding(.vertical, 10)
        .padding(.trailing, 10)

        .onChange(of: app.current?.id) { _, _ in
            summaryDraft = clipNote?.metaFields[ClipFields.summary] ?? ""
            tagInput = ""
        }
        .onAppear {
            summaryDraft = clipNote?.metaFields[ClipFields.summary] ?? ""
        }
        .alert("删除这篇剪藏？", isPresented: $isConfirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let clip = clipNote { app.deleteClip(id: clip.id) }
            }
        } message: {
            let refs = clipNote.map { app.clipReferenceCount(id: $0.id) } ?? 0
            Text(refs > 0
                 ? "有 \(refs) 篇笔记引用它，删除后这些引用会变成悬空。"
                 : "这个操作不能撤销。")
        }
    }

    // MARK: - 页签

    /// `详情` / `AI` 两个页签。选择落 `AISettings`，下次启动沿用。
    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach([AISettings.PanelTab.details, AISettings.PanelTab.ai], id: \.rawValue) { tab in
                let selected = app.aiPanel == tab
                Button {
                    app.setAIPanel(tab)
                } label: {
                    Text(tab == .details ? "详情" : "AI")
                        .font(PanelFont.label(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Tokens.ink : Tokens.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.row, style: .continuous)
                                .fill(selected ? Tokens.selectedFill : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab == .details ? "来源与连接" : "向 AI 提问")
                .accessibilityIdentifier("context-tab-\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var detailsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if app.nav.active == .journal, app.nav.journalScope == .todos {
                    Text("待办总览占满中栏，右栏留空。")
                        .font(PanelFont.text())
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                } else if app.nav.active == .journal, app.nav.journalScope == .templates {
                    Text("模板是配置页，右栏留空。")
                        .font(PanelFont.text())
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                } else if let clip = clipNote {
                    clipSections(clip)
                } else if let note = app.current, note.type == NoteTypes.journalID {
                    // 日记不能被引用（linkable = false），只看出链与提及。
                    journalSection(note)
                    backlinkSection
                    mentionSection
                } else if app.current == nil {
                    Text(emptyHint)
                        .font(PanelFont.text())
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                } else {
                    backlinkSection
                    mentionSection
                    outgoingSection
                    danglingSection
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 剪藏

    @ViewBuilder
    private func clipSections(_ clip: Note) -> some View {
        let meta = clip.metaFields
        let status = ClipStatus(rawValue: meta[ClipFields.status] ?? "") ?? .unread
        let aiState = ClipAIState(rawValue: meta[ClipFields.aiState] ?? "") ?? .pending

        // 来源
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("来源")
            VStack(alignment: .leading, spacing: 5) {
                sourceRow("站点", meta[ClipFields.site])
                sourceRow("作者", meta[ClipFields.author])
                sourceRow("发布时间", meta[ClipFields.published])
                sourceRow("抓取时间", Self.dateText(clip.createdAt))
                sourceRow("字数", "\(clip.body.count)")
                if let raw = meta[ClipFields.url], !raw.isEmpty, let url = URL(string: raw) {
                    Link(destination: url) {
                        Label("打开原文", systemImage: "arrow.up.right.square")
                            .font(PanelFont.label())
                    }
                }
                if let model = meta[ClipFields.aiModel], !model.isEmpty {
                    sourceRow("整理模型", model)
                }
            }
        }

        // 摘要
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle("摘要")
                if aiState != .done {
                    Text(aiState.label)
                        .font(PanelFont.meta())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    isSummarizing = true
                    Task {
                        let message = await app.retryClipSummary(id: clip.id)
                        isSummarizing = false
                        if let message { app.statusMessage = "重新整理失败：\(message)" }
                        summaryDraft = clipNote?.metaFields[ClipFields.summary] ?? ""
                    }
                } label: {
                    if isSummarizing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("重新整理").font(PanelFont.label())
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isSummarizing || app.clipProvider() == nil)
                .help(app.clipProvider() == nil ? "先在设置里配置对话模型" : "用当前模型重新生成摘要与标签")
            }
            TextEditor(text: $summaryDraft)
                .font(PanelFont.text())
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Tokens.rail)
                )
                .onChange(of: summaryDraft) { _, value in
                    guard clipNote?.id == clip.id else { return }
                    summarySaveTask?.cancel()
                    summarySaveTask = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            if value != clip.metaFields[ClipFields.summary] {
                                app.updateClipSummary(id: clip.id, summary: value)
                            }
                        }
                    }
                }
        }

        // 标签
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("标签", count: clip.tagNames.count)
            if clip.tagNames.isEmpty {
                hint("还没有标签。模型未配置时可以手动加。")
            } else {
                FlowTags(tags: clip.tagNames) { name in
                    app.updateClipTags(id: clip.id, tags: clip.tagNames.filter { $0 != name })
                }
            }
            HStack(spacing: 6) {
                TextField("加标签，回车确认", text: $tagInput)
                    .textFieldStyle(.roundedBorder)
                    .font(PanelFont.label())
                    .onSubmit { addTag(to: clip) }
                Button("添加") { addTag(to: clip) }
                    .buttonStyle(.borderless)
                    .font(PanelFont.label())
                    .disabled(ClipTagPolicy.sanitize(tagInput) == nil)
            }
        }

        // 被引用
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("被引用", count: app.backlinks.count)
            if app.backlinks.isEmpty {
                hint("还没有笔记引用它。在概念笔记或日记里写 [[\(clip.title)]] 即可。")
            } else {
                ForEach(app.backlinks) { backlink in
                    Button {
                        app.select(backlink.sourceId)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backlinkLabel(backlink))
                                .font(PanelFont.text(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(backlink.snippet)
                                .font(PanelFont.meta())
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Tokens.rail)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        // 操作
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("操作")
            HStack(spacing: 8) {
                Button(status == .unread ? "标记已读" : "标记未读") {
                    app.setClipStatus(id: clip.id, status: status == .unread ? .read : .unread)
                }
                Button(status == .archived ? "取消归档" : "归档") {
                    app.setClipStatus(id: clip.id, status: status == .archived ? .read : .archived)
                }
                Button("导出") { exportCurrent(clip) }
                Button("删除", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
            .font(PanelFont.label())
            .buttonStyle(.borderless)
        }
    }

    private func exportCurrent(_ clip: Note) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ClipExport.fileName(for: clip)
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try app.exportClip(id: clip.id, to: url)
            app.statusMessage = "已导出到 \(url.lastPathComponent)"
        } catch {
            app.statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func addTag(to clip: Note) {
        guard let clean = ClipTagPolicy.sanitize(tagInput) else { return }
        let merged = clip.tagNames + [clean]
        app.updateClipTags(id: clip.id, tags: merged)
        tagInput = ""
    }

    private func sourceRow(_ label: String, _ value: String?) -> some View {
        Group {
            if let value, !value.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(PanelFont.meta())
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .leading)
                    Text(value)
                        .font(PanelFont.label())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
    }

    private func backlinkLabel(_ backlink: Backlink) -> String {
        guard let source = app.summaries.first(where: { $0.id == backlink.sourceId }),
              source.type == NoteTypes.journalID
        else { return backlink.sourceTitle }
        return "日记 · \(backlink.sourceTitle)"
    }

    private static func dateText(_ ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: - 反向链接

    private var backlinkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("反向链接", count: app.backlinks.count)

            if app.backlinks.isEmpty {
                hint("还没有笔记引用这一条。写在别的笔记里用 [[标题]] 即可。")
            } else {
                ForEach(app.backlinks) { backlink in
                    Button {
                        app.select(backlink.sourceId)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backlink.sourceTitle)
                                .font(PanelFont.text(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(backlink.snippet)
                                .font(PanelFont.meta())
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Tokens.rail)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 出链

    private var outgoingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("引用出去", count: app.outgoing.count)

            if app.outgoing.isEmpty {
                hint("这一条还没有引用别的笔记。输入 [[ 会弹出补全。")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(app.outgoing.enumerated()), id: \.offset) { _, link in
                        Button {
                            app.openTitle(link.rawTarget)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: link.status == .resolved ? "arrow.up.right" : "questionmark.circle.dashed")
                                    .font(PanelFont.meta())
                                    .foregroundStyle(link.status == .resolved ? Color.accentColor : Color.secondary)
                                Text(link.displayText)
                                    .font(PanelFont.text())
                                    .foregroundStyle(link.status == .resolved ? .primary : .secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 未链接提及

    private var mentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("未链接提及")
                    .font(PanelFont.label(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text("\(app.mentions.count)")
                    .font(PanelFont.label(.semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                if !app.mentions.isEmpty {
                    Button("整理") {
                        app.refreshMentionGroups()
                        app.isShowingMentionsSheet = true
                    }
                    .buttonStyle(.link)
                    .font(PanelFont.label())
                }
            }

            // 日记默认不跑提及扫描，开关放在这里，和「未链接提及」同一语义位置。
            if app.current?.type == NoteTypes.journalID {
                HStack(spacing: 6) {
                    Toggle("日记参与提及扫描", isOn: Binding(
                        get: { app.journalScanMentions },
                        set: { app.setJournalScanMentions($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Text(app.journalScanMentions ? "已开启" : "已关闭")
                        .font(PanelFont.label())
                        .foregroundStyle(.secondary)
                }
                .font(PanelFont.label())
            }

            if app.mentions.isEmpty {
                if app.current?.type == NoteTypes.journalID, !app.journalScanMentions {
                    hint("已关闭：日记不参与提及扫描。打开上面的开关后，正文里写到已有概念标题会出现在这里。")
                } else {
                    hint("正文里写到已有标题时，这里会出现。点中带点状下划线的文字按 ⌘⇧K 可转成引用。")
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.mentions) { mention in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: mention.kind == .alias ? "tag" : "link")
                                .font(PanelFont.meta())
                                .foregroundStyle(Color(nsColor: Theme.mentionUnderline))
                                .padding(.top, 3)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mention.targetTitle)
                                    .font(PanelFont.text())
                                    .lineLimit(1)
                                Text(mention.snippet)
                                    .font(PanelFont.label())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)

                            Button {
                                app.select(mention.noteId)
                            } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(PanelFont.meta())
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("回到这篇笔记")

                            Button {
                                app.dismissMention(id: mention.id)
                            } label: {
                                Image(systemName: "eye.slash")
                                    .font(PanelFont.meta())
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("忽略这条提及")
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: - 悬空

    private var danglingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("悬空引用", count: app.danglingTargets.count)
            if app.danglingTargets.isEmpty {
                hint("没有指向不存在笔记的引用。")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.danglingTargets, id: \.self) { target in
                        Button {
                            _ = app.createIfNeeded(title: target)
                            app.loadAll()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus.circle.dashed")
                                    .font(PanelFont.meta())
                                    .foregroundStyle(.secondary)
                                Text(target)
                                    .font(PanelFont.text())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("按这个标题新建一条笔记")
                    }
                }
            }
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(PanelFont.label(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyHint: String {
        switch app.nav.active {
        case .journal:
            return app.nav.journalScope == .todos ? "待办总览占满中栏，右栏留空。" : "选一篇日记查看当天的连接"
        case .clips:
            return "选一篇剪藏查看来源与被引用"
        case .notes:
            return "选一条笔记查看连接"
        }
    }

    /// 日记右栏：当天统计 + 承接来源。
    private func journalSection(_ note: Note) -> some View {
        let entry = app.journalEntries.first { $0.id == note.id }
        let carried = note.metaFields["carryFrom"] ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("当天", count: entry?.openTodoCount ?? 0)
            VStack(alignment: .leading, spacing: 5) {
                sourceRow("日期", entry?.date ?? note.title)
                sourceRow("星期", entry?.weekday ?? "")
                sourceRow("未完成", "\(entry?.openTodoCount ?? 0) 条")
                sourceRow("承接自", carried.isEmpty ? "无" : carried)
                sourceRow("字数", "\(note.body.count)")
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(PanelFont.label(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(PanelFont.label(.semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(PanelFont.label())
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}


// MARK: - 标签流式布局

private struct FlowTags: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 5) {
                    Text("#\(tag)")
                        .font(PanelFont.label())
                        .foregroundStyle(.secondary)
                    Button {
                        onRemove(tag)
                    } label: {
                        Image(systemName: "xmark")
                            .font(PanelFont.meta())
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("移除标签")
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
