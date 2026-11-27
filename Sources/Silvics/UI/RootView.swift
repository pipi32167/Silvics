import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        GeometryReader { geo in
            split
                .onAppear {
                    app.setWindowWidth(geo.size.width)
                    #if DEBUG
                    runDebugHooks()
                    #endif
                }
                .onChange(of: geo.size.width) { _, width in
                    app.setWindowWidth(width)
                }
        }
        .sheet(isPresented: $app.isShowingNewNote) {
            NewNoteSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $app.isShowingNewClip) {
            NewClipSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $app.isShowingMentionsSheet) {
            MentionSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $app.isShowingAliasSheet) {
            AliasSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $app.isShowingRenameSheet) {
            RenameSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $app.isShowingConflicts) {
            ConflictSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $app.isShowingQuickOpen) {
            QuickOpenSheet()
                .environmentObject(app)
        }
        .overlay(alignment: .bottom) {
            StatusBanner()
        }
    }

    /// 四栏骨架：模块导航 | 列表 | 内容 | 右栏。
    ///
    /// 系统 `NavigationSplitView` 只支持三列，所以第一列交给它管，
    /// 后三列放进 `HSplitView`，列表栏收起只是把那一列拿掉。
    private var split: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModuleNavView()
                .navigationSplitViewColumnWidth(
                    min: app.isNavCollapsed ? 46 : 140,
                    ideal: app.isNavCollapsed ? 46 : 156,
                    max: app.isNavCollapsed ? 46 : 200
                )
        } detail: {
            HStack(spacing: 0) {
                if app.isListPaneVisible {
                    ListPaneView()
                        .frame(width: app.listPaneWidth)
                    ListPaneResizeHandle()
                }
                HSplitView {
                    ContentPane()
                        .frame(minWidth: 320, idealWidth: 680, maxWidth: .infinity)
                    ContextPanelView()
                        .background(Tokens.paper)
                        .frame(
                            minWidth: contextPanelWidth.min,
                            idealWidth: contextPanelWidth.ideal,
                            maxWidth: contextPanelWidth.max
                        )
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.toggleNavPane()
                } label: {
                    Image(systemName: app.isNavCollapsed ? "sidebar.right" : "sidebar.left")
                }
                .help(app.isNavCollapsed ? "展开模块栏 ⌘⌥S" : "收成图标栏 ⌘⌥S")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    app.toggleListPane()
                } label: {
                    Image(systemName: app.isListPaneVisible ? "sidebar.left" : "sidebar.right")
                }
                .help(app.isListPaneVisible ? "隐藏列表栏 ⌘⌥L" : "显示列表栏 ⌘⌥L")
            }
        }
    }

    /// 右栏宽度。取证时可用 `SILVICS_CONTEXT_WIDTH=200` 压到最窄，验证窄栏布局。
    private var contextPanelWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SILVICS_CONTEXT_WIDTH"],
           let width = Double(raw), width > 0 {
            return (width, width, width)
        }
        #endif
        return (200, 292, 380)
    }

    #if DEBUG
    /// 仅 DEBUG：演示数据与取证钩子。放在 onAppear 里跑，顺序保持不变。
    private func runDebugHooks() {
        if DemoSeeder.isRequested {
            let n = DemoSeeder.seedIfEmpty(app)
            if n > 0 { print("[Silvics] seeded \(n) notes") }
        }
        DebugCapture.selectPinyinInputSourceIfRequested()
        DebugCapture.applyShowFlag(app)
        DebugCapture.runSelfTest(app)
        DebugCapture.runConflictDrill(app)
        DebugCapture.seedConflictDemo(app)
        DebugCapture.applyCaretProbe()
        DebugCapture.startCursorProbe()
        DebugCapture.schedule()
    }
    #endif
}

// MARK: - 状态条

private struct StatusBanner: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if let message = app.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.system(size: 12))
                        .lineLimit(3)
                    Spacer(minLength: 8)
                    Button {
                        app.clearStatus()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .padding(16)
                .frame(maxWidth: 560)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: app.statusMessage)
    }
}

// MARK: - 列表栏分隔条

/// 拖动改列表栏宽度，松手落盘。宽度有上下限，见 `ListPaneSettings`。
private struct ListPaneResizeHandle: View {
    @EnvironmentObject private var app: AppState
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStart ?? app.listPaneWidth
                                if dragStart == nil { dragStart = start }
                                app.setListPaneWidth(start + value.translation.width)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            )
    }
}

// MARK: - 中栏

/// 中栏按模块切换：笔记与日记用编辑器，剪藏用只读阅读视图，
/// 日记的「待办总览」「模板」占满中栏，不再弹 sheet。
private struct ContentPane: View {
    @EnvironmentObject private var app: AppState

    @ViewBuilder
    var body: some View {
        switch app.nav.active {
        case .notes, .clips:
            EditorPane()
        case .journal:
            switch app.nav.journalScope {
            case .todos:
                TodoOverviewView()
            case .templates:
                JournalTemplateView()
            case .today, .all:
                EditorPane()
            }
        }
    }
}

// MARK: - 编辑区外壳

private struct EditorPane: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let note = app.current {
                if note.type == NoteTypes.clipID {
                    ClipReaderView(note: note)
                        .id(note.id)
                } else {
                    NoteEditorView(
                        initialText: note.body,
                        text: note.body,
                        textRevision: app.bodyRevision,
                        liveText: { app.current?.body ?? note.body },
                        resolvedKeys: app.resolvedKeys,
                        mentions: app.mentionDecorations(),
                        appearance: app.appearance,
                        onChange: { text in app.bodyDidChange(text) },
                        completionProvider: { query, limit in app.completionItems(query: query, limit: limit) },
                        onCreateNote: { title in app.createIfNeeded(title: title) },
                        onOpenLink: { title in app.openTitle(title) },
                        onCompletionVisibilityChange: { visible in app.setCompletionVisible(visible) }
                    )
                    .id(note.id)
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.paper)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let note = app.current {
                Button {
                    app.isShowingRenameSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text(note.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!note.noteType.titleEditable)
                .help(note.noteType.titleEditable
                      ? "重命名。正文里的旧引用会跟着改。"
                      : "日记的标题就是日期，不能改。")

                if note.type == NoteTypes.clipID {
                    clipStatusLabel(note)
                } else {
                    statusPicker
                }

                if note.type == NoteTypes.journalID {
                    journalActions
                }

                if !app.aliases.isEmpty {
                    Label("\(app.aliases.count)", systemImage: "tag")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("别名：" + app.aliases.joined(separator: "、"))
                }

                Spacer()

                Text("\(note.body.count) 字")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("没有选中笔记")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 34)
    }

    /// 日记专用：把上一篇的未完成项并进同名段、选下次新建的模板。
    private var journalActions: some View {
        HStack(spacing: 2) {
            Button {
                app.mergePreviousTodos()
            } label: {
                Label("融合", systemImage: "arrow.down.to.line")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("把上一个有日记的日子的未完成待办并进同名段。")
            .accessibilityIdentifier("journal-merge")

            Button {
                app.applyScope(.journal(.templates))
            } label: {
                Label("模板", systemImage: "square.grid.2x2")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("勾选下一次新建日记要用的模板。已有日记正文不受影响。")
            .accessibilityIdentifier("journal-templates")
        }
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
    }

    /// 剪藏用阅读状态，不用成熟度。
    private func clipStatusLabel(_ note: Note) -> some View {
        let status = ClipStatus(rawValue: note.metaFields[ClipFields.status] ?? "") ?? .unread
        return Menu {
            ForEach(ClipStatus.allCases, id: \.self) { value in
                Button {
                    app.setClipStatus(id: note.id, status: value)
                } label: {
                    Text(value.label)
                }
            }
        } label: {
            Label(status.label, systemImage: status == .archived ? "archivebox" : "bookmark")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var statusPicker: some View {
        Menu {
            ForEach(NoteStatus.allCases, id: \.self) { status in
                Button {
                    app.updateStatus(status)
                } label: {
                    Label(status.label, systemImage: status.symbolName)
                }
            }
        } label: {
            if let note = app.current {
                Label(note.status.label, systemImage: note.status.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: emptyIcon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.quaternary)
            Text(emptyText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        switch app.nav.active {
        case .notes: return "tree"
        case .journal: return "calendar"
        case .clips: return "bookmark"
        }
    }

    private var emptyText: String {
        switch app.nav.active {
        case .notes:
            return "选一条笔记，或按 ⌘N 新建"
        case .journal:
            return "选一篇日记，或按 ⌘⇧J 打开今天"
        case .clips:
            return "选一篇剪藏，或按 ⌘⇧V 收一篇"
        }
    }
}
