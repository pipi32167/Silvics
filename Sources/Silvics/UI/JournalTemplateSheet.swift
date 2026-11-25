import SwiftUI

/// 日记「模板…」：勾选下一次新建日记要用的模板。
///
/// 记忆落 `JournalTemplateMemory`（UserDefaults）。只影响之后新建的日记，
/// 已有日记的正文一个字都不改。默认勾选与 `journalTemplateNames()` 一致：
/// 记忆优先，记忆失效时是 order 最小的前两个。
struct JournalTemplateSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []

    private var choices: [JournalTemplate] {
        app.journalTemplateChoices()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 430, height: 360)
        .onAppear {
            selected = Set(app.journalTemplateNames())
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("日记模板")
                .font(.system(size: 15, weight: .medium))
            Text("下次新建时生效")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    @ViewBuilder
    private var list: some View {
        if choices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("vault 里还没有模板")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("往 templates/ 放一份带 `template:` 段的 `.md`，重开这个面板就能选。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(choices, id: \.name) { template in
                        Toggle(isOn: binding(for: template.name)) {
                            HStack(spacing: 6) {
                                Text(template.name)
                                    .font(.system(size: 12))
                                Text(orderLabel(template.order))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已在日记里写下的正文不受影响：勾选只决定骨架，不重写历史。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("按 order 最小的前两个") {
                    selected = Set(app.defaultJournalTemplateNames())
                }
                .controlSize(.small)
                .disabled(choices.isEmpty)

                Spacer()

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)

                Button("保存") {
                    app.setJournalTemplateNames(orderedSelection())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(name) },
            set: { on in
                if on { selected.insert(name) } else { selected.remove(name) }
            }
        )
    }

    /// 按 order 顺序落记忆，避免勾选顺序决定保存顺序。
    private func orderedSelection() -> [String] {
        choices.map(\.name).filter { selected.contains($0) }
    }

    private func orderLabel(_ order: Int) -> String {
        order == JournalTemplates.unorderedOrder ? "order 未标注" : "order \(order)"
    }
}
