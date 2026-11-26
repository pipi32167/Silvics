import SwiftUI

/// AI 提问设置。全部即时生效，没有保存按钮。
struct AISettingsPane: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("系统提示词")
                    TextEditor(text: binding(\.systemPrompt))
                        .font(.system(size: 12))
                        .frame(minHeight: 96)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                        .accessibilityIdentifier("ai-system-prompt")
                    Text("每次请求都带上。正文与网页内容会附在后面，并标明是不可信数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("提示词")
            }

            Section {
                ForEach($app.aiSettings.prompts) { $template in
                    promptRow($template)
                }
                HStack(spacing: 10) {
                    Button("新增提示词") { addPrompt() }
                    Button("恢复默认提示词") { app.resetAIPrompts() }
                    Spacer()
                }
                .font(.system(size: 12))
            } header: {
                Text("常用提示词")
            } footer: {
                Text("内置 4 条可改正文，不能删除。恢复默认只还原内置项，自定义项会清空。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("正文上限", selection: binding(\.bodyLimit)) {
                    ForEach(AISettings.allowedBodyLimits, id: \.self) { limit in
                        Text(limit == 0 ? "不带正文" : "\(limit) 字").tag(limit)
                    }
                }
                .pickerStyle(.menu)

                Picker("历史轮数", selection: binding(\.historyRounds)) {
                    ForEach(AISettings.allowedHistoryRounds, id: \.self) { rounds in
                        Text("\(rounds) 轮").tag(rounds)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("上下文")
            } footer: {
                Text("超限时先丢最早的历史，再截正文。引用与当前正文不会被丢掉。一轮等于一问一答。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("会话存储") {
                    Text("vault/ai/<笔记 id>.jsonl").foregroundStyle(.secondary)
                }
                LabeledContent("单个会话上限") {
                    Text("\(AISettings.maxMessages) 条 / \(AISettings.maxFileBytes / 1024) KB")
                        .foregroundStyle(.secondary)
                }
                Text("会话跟着 vault 同步。vault 推到公开仓库时，提问与回答也会一起公开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("同步")
            }

            Section {
                HStack {
                    Button("恢复默认") {
                        app.updateAISettings(AISettings())
                    }
                    Spacer()
                }
            } header: {
                Text("重置")
            } footer: {
                Text("只重置这一页的设置，不动已存的会话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func promptRow(_ template: Binding<AIPromptTemplate>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if template.wrappedValue.builtin {
                    Text(template.wrappedValue.title)
                        .font(.system(size: 12, weight: .medium))
                    Text("内置")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                } else {
                    TextField("标题", text: template.title)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.system(size: 11))
                        .frame(maxWidth: 200)
                }
                Spacer(minLength: 0)
                if !template.wrappedValue.builtin {
                    Button {
                        removePrompt(id: template.wrappedValue.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("删除这条提示词")
                }
            }
            TextField("提示词正文", text: template.body, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 11))
                .lineLimit(1...3)
        }
        .padding(.vertical, 2)
    }

    private func addPrompt() {
        var settings = app.aiSettings
        settings.prompts.append(
            AIPromptTemplate(
                id: "custom-\(UUID().uuidString.prefix(8))",
                title: "新提示词",
                body: "",
                builtin: false
            )
        )
        app.updateAISettings(settings)
    }

    private func removePrompt(id: String) {
        var settings = app.aiSettings
        settings.prompts.removeAll { $0.id == id && !$0.builtin }
        app.updateAISettings(settings)
    }

    /// 每次改动都先 `repaired()` 再落盘，界面不会出现半截状态。
    private func binding<Value>(_ keyPath: WritableKeyPath<AISettings, Value>) -> Binding<Value> {
        Binding(
            get: { app.aiSettings[keyPath: keyPath] },
            set: { newValue in
                var settings = app.aiSettings
                settings[keyPath: keyPath] = newValue
                app.updateAISettings(settings)
            }
        )
    }
}
