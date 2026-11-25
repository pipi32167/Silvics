import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            EditorPane()
                .navigationSplitViewColumnWidth(min: 420, ideal: 680)
        } detail: {
            ContextPanelView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        }
        .sheet(isPresented: $app.isShowingNewNote) {
            NewNoteSheet()
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
        .sheet(isPresented: $app.isShowingTodoOverview) {
            TodoOverviewSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $app.isShowingJournalTemplateSheet) {
            JournalTemplateSheet()
                .environmentObject(app)
        }
        .overlay(alignment: .bottom) {
            StatusBanner()
        }
        .onAppear {
            #if DEBUG
            if DemoSeeder.isRequested {
                let n = DemoSeeder.seedIfEmpty(app)
                if n > 0 { print("[Silvics] seeded \(n) notes") }
            }
            DebugCapture.applyShowFlag(app)
            DebugCapture.runSelfTest(app)
            DebugCapture.runConflictDrill(app)
            DebugCapture.seedConflictDemo(app)
            DebugCapture.applyCaretProbe()
            DebugCapture.schedule()
            #endif
        }
    }
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

// MARK: - 编辑区外壳

private struct EditorPane: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let note = app.current {
                NoteEditorView(
                    initialText: note.body,
                    text: note.body,
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
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
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

                statusPicker

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

    /// 日记专用：把上一篇的未完成项插到当前行之前、选下次新建的模板。
    private var journalActions: some View {
        HStack(spacing: 2) {
            Button {
                app.insertCarryAtCaret()
            } label: {
                Label("承接", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("把上一个有日记的日子的未完成项插到光标所在行之前。")
            .accessibilityIdentifier("journal-carry")

            Button {
                app.isShowingJournalTemplateSheet = true
            } label: {
                Label("模板…", systemImage: "square.grid.2x2")
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
            Image(systemName: "tree")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.quaternary)
            Text("选一条笔记，或按 ⌘N 新建")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
