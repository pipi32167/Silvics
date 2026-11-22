import SwiftUI

/// 改名。这一步会改全库正文，所以先给影响范围，再让用户确认。
struct RenameSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private var trimmed: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var impact: [RenameImpact] { app.renameImpact(newTitle: trimmed) }

    private var occurrenceCount: Int { impact.reduce(0) { $0 + $1.occurrences } }

    private var canSubmit: Bool {
        !trimmed.isEmpty
            && TextNormalizer.validateTitle(trimmed) == nil
            && trimmed != (app.current?.title ?? "")
            && !app.duplicateTitleExists(trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名")
                .font(.system(size: 15, weight: .semibold))

            TextField("新的标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit { commit() }

            messageLine

            if !impact.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("正文会跟着改：\(occurrenceCount) 处引用，\(impact.count) 篇笔记")
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(impact) { row in
                                HStack(spacing: 6) {
                                    Text(row.noteTitle)
                                        .font(.system(size: 11.5))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(row.occurrences) 处")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }

            Text("旧标题会自动成为别名，别处写旧标题仍然能连到这条笔记。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .onAppear {
            title = app.current?.title ?? ""
            fieldFocused = true
        }
    }

    @ViewBuilder
    private var messageLine: some View {
        if app.duplicateTitleExists(trimmed), trimmed != (app.current?.title ?? "") {
            label("已有同名笔记，不能改成这个标题。", warning: true)
        } else if let validation = TextNormalizer.validateTitle(trimmed), !trimmed.isEmpty {
            label(validation, warning: true)
        } else if let errorMessage {
            label(errorMessage, warning: true)
        } else {
            label("标题变了，正文里的旧引用会一起改写。", warning: false)
        }
    }

    private func label(_ text: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 9))
                .foregroundStyle(warning ? Color.orange : Color.secondary)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commit() {
        guard canSubmit else { return }
        errorMessage = app.rename(newTitle: trimmed)
        if errorMessage == nil { dismiss() }
    }
}
