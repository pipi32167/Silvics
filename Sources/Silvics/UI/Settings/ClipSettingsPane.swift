import SwiftUI

/// 剪藏设置。全部即时生效，没有保存按钮。
struct ClipSettingsPane: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle(isOn: binding(\.autoSummarize)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("抓取后自动整理")
                        Text("关掉只保存正文，列表标「待整理」，之后可手动整理。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("标题来源", selection: binding(\.titleStrategy)) {
                    ForEach(ClipTitleStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.label).tag(strategy)
                    }
                }
                .pickerStyle(.menu)
                Text(titleStrategyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("摘要长度", selection: binding(\.summaryLimit)) {
                    Text("短（150 字）").tag(150)
                    Text("标准（300 字）").tag(300)
                    Text("长（500 字）").tag(500)
                }
                .pickerStyle(.menu)
                Picker("目标标签数", selection: binding(\.targetTagCount)) {
                    ForEach(ClipSettings.allowedTagCounts, id: \.self) { count in
                        Text("\(count) 个").tag(count)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("整理")
            } footer: {
                Text("新标签每次最多 2 个。已有标签优先，不够 3 个时不自动补。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("抓取超时", selection: binding(\.fetchTimeout)) {
                    ForEach(ClipSettings.allowedTimeouts, id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("大小上限") {
                    Text("5 MB").foregroundStyle(.secondary)
                }
            } header: {
                Text("抓取")
            } footer: {
                Text("超时或超过上限时停止抓取，可改用粘贴正文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: binding(\.markReadOnOpen)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("打开即标已读")
                        Text("关掉后只手动改阅读状态。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("阅读")
            }

            Section {
                HStack {
                    Button("恢复默认") {
                        app.resetClipSettings()
                    }
                    Spacer()
                    Text("改动即时生效")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Tokens.paper)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }

    private var titleStrategyHint: String {
        switch app.clipSettings.titleStrategy {
        case .smart: return "原文标题或文件名优先，缺失才让模型提炼。"
        case .alwaysModel: return "一律让模型按正文重写标题。"
        case .never: return "不调模型取标题：有就用，缺失取正文首行。"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ClipSettings, Value>) -> Binding<Value> {
        Binding(
            get: { app.clipSettings[keyPath: keyPath] },
            set: { value in
                var settings = app.clipSettings
                settings[keyPath: keyPath] = value
                app.updateClipSettings(settings)
            }
        )
    }
}
