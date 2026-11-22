import SwiftUI

/// 别名管理。别名是标题的第二个入口：正文写别名也算提到这条笔记。
struct AliasSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var input: String = ""
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    private var title: String { app.current?.title ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("别名")
                .font(.system(size: 15, weight: .semibold))
            Text("《\(title)》")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            if app.aliases.isEmpty {
                Text("还没有别名。加上同义说法，正文写到它时也会提示建立引用。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(app.aliases, id: \.self) { alias in
                            HStack(spacing: 8) {
                                Image(systemName: "tag")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(alias)
                                    .font(.system(size: 12))
                                Spacer()
                                Button {
                                    app.removeAlias(alias)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("删除这个别名")
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("加一个别名，例如「遗忘规律」", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($inputFocused)
                    .onSubmit { add() }
                Button("添加") { add() }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 380)
        .onAppear { inputFocused = true }
    }

    private func add() {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        errorMessage = app.addAlias(name)
        if errorMessage == nil { input = "" }
    }
}
