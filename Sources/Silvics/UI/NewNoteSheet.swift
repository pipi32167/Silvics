import SwiftUI

/// 新建笔记。这一步是产品最重要的守门：
/// 标题必须是一句可读的断言，且不能与已有笔记重复。
struct NewNoteSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var validationMessage: String?
    @FocusState private var titleFocused: Bool

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var similar: [(summary: NoteSummary, score: Double)] {
        app.similarNotes(for: trimmed)
    }

    private var canCreate: Bool {
        !trimmed.isEmpty && validationMessage == nil && !app.duplicateTitleExists(trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新笔记")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                TextField("写成一句断言，例如「稀疏重复优于集中突击」", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($titleFocused)
                    .onSubmit { commit() }
                    .onChange(of: title) { _, _ in validate() }

                messageLine
            }

            if !similar.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("相似笔记（避免重复）")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)

                    ForEach(similar, id: \.summary.id) { item in
                        Button {
                            app.select(item.summary.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.summary.status.symbolName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(item.summary.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                Text(String(format: "%.2f", item.score))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.045))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建笔记") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 480, height: 300)
        .onAppear { titleFocused = true }
    }

    @ViewBuilder
    private var messageLine: some View {
        if app.duplicateTitleExists(trimmed), !trimmed.isEmpty {
            label("已有同名笔记。打开它，别新建第二条。", tone: .warning)
        } else if let validationMessage {
            label(validationMessage, tone: .warning)
        } else if !trimmed.isEmpty {
            label("标题会被正文以 [[\(trimmed)]] 的形式引用。", tone: .neutral)
        } else {
            label("不要写日期，不要写「读书笔记 3」。写成一句能被别处引用的断言。", tone: .neutral)
        }
    }

    private enum Tone { case neutral, warning }

    private func label(_ text: String, tone: Tone) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(tone == .warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func validate() {
        validationMessage = trimmed.isEmpty ? nil : TextNormalizer.validateTitle(trimmed)
    }

    private func commit() {
        validate()
        guard canCreate else { return }
        _ = app.createNote(title: trimmed)
        dismiss()
    }
}
