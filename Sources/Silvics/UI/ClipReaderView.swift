import AppKit
import SwiftUI

/// 剪藏阅读视图。复用 Typora 式编辑器：
/// 只读时整篇按渲染态显示，不解析 `[[ ]]`，待办框不给点。
struct ClipReaderView: View {
    @EnvironmentObject private var app: AppState
    let note: Note

    @State private var isEditing = false
    @State private var draftBody: String = ""

    private var meta: [String: String] { note.metaFields }
    private var site: String { meta[ClipFields.site] ?? "" }
    private var author: String { meta[ClipFields.author] ?? "" }
    private var url: String { meta[ClipFields.url] ?? "" }
    private var published: String { meta[ClipFields.published] ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            metaBar
            Divider()
            editor
        }
        .onAppear { draftBody = note.body }
        .onDisappear { flushBodyIfNeeded() }
        .onChange(of: isEditing) { _, editing in
            if !editing { flushBodyIfNeeded() }
        }
    }

    // MARK: - 来源行

    private var metaBar: some View {
        HStack(spacing: 8) {
            if !site.isEmpty {
                Text(site)
                    .font(.system(size: Tokens.TypeScale.label.size, weight: .medium))
                    .foregroundStyle(Tokens.ink2)
            }
            if !author.isEmpty {
                Text(author)
                    .font(.system(size: Tokens.TypeScale.label.size))
                    .foregroundStyle(Tokens.ink3)
            }
            if !published.isEmpty {
                Text(published)
                    .font(.system(size: Tokens.TypeScale.label.size))
                    .foregroundStyle(Tokens.ink3)
            }
            if !url.isEmpty, let link = URL(string: url) {
                Link(destination: link) {
                    Label("原文", systemImage: "arrow.up.right.square")
                        .font(.system(size: Tokens.TypeScale.label.size))
                        .foregroundStyle(Tokens.accent)
                }
            }
            Spacer()
            Button {
                isEditing.toggle()
            } label: {
                Label(isEditing ? "完成编辑" : "编辑正文", systemImage: isEditing ? "checkmark" : "pencil")
                    .font(.system(size: Tokens.TypeScale.label.size))
                    .foregroundStyle(Tokens.ink2)
            }
            .buttonStyle(.borderless)
            .help("剪藏正文默认只读。修正抽取错误时才需要打开编辑。")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: 30)
        .background(Tokens.paper)
    }

    // MARK: - 正文

    @ViewBuilder
    private var editor: some View {
        NoteEditorView(
            initialText: note.body,
            text: isEditing ? draftBody : note.body,
            // 剪藏正文只靠 `updatedAt` 当外部改写的版本号：库里改了正文，读视图跟着重画。
            textRevision: Int(truncatingIfNeeded: note.updatedAt),
            liveText: { isEditing ? draftBody : note.body },
            resolvedKeys: app.resolvedKeys,
            mentions: [],
            appearance: app.appearance,
            editable: isEditing,
            rendersWikiLinks: false,
            onChange: { value in
                if isEditing { draftBody = value }
            },
            completionProvider: { _, _ in [] },
            onCreateNote: { _ in nil },
            onOpenLink: { _ in },
            onCompletionVisibilityChange: { _ in }
        )
        .id("\(note.id)-\(isEditing)")
    }

    private func flushBodyIfNeeded() {
        guard isEditing, draftBody != note.body else { return }
        app.updateClipBody(id: note.id, body: draftBody)
    }
}
