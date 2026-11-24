import SwiftUI

/// 外观设置。
///
/// 全部即时生效：拖动即写入 UserDefaults 并重排编辑区样式。
/// 改的是渲染参数，不碰正文——`note.body` 永远是纯文本。
struct AppearanceSettingsPane: View {
    @EnvironmentObject private var app: AppState

    @State private var draft = AppearanceSettings()
    @State private var isLoaded = false

    var body: some View {
        Form {
            previewSection

            Section {
                LabeledContent("正文字号") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.bodySize, in: AppearanceSettings.bodySizeRange, step: 1)
                            .frame(width: 190)
                        Text("\(Int(draft.bodySize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                LabeledContent("代码字号") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.codeSize, in: AppearanceSettings.codeSizeRange, step: 0.5)
                            .frame(width: 190)
                        Text(String(format: "%.1f pt", draft.codeSize))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                LabeledContent("行距") {
                    HStack(spacing: 12) {
                        Slider(value: $draft.lineSpacing, in: AppearanceSettings.lineSpacingRange, step: 1)
                            .frame(width: 190)
                        Text("\(Int(draft.lineSpacing)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            } header: {
                Text("文字")
            } footer: {
                Text("标题字号按正文比例缩放：正文 15 时一级标题 26。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("字体") {
                Picker("字体族", selection: $draft.fontFamily) {
                    ForEach(AppearanceSettings.FontFamily.allCases) { family in
                        Text(family.title).tag(family)
                    }
                }
                .pickerStyle(.segmented)

                Text("只影响编辑区渲染，不写进笔记正文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    Button("恢复默认") {
                        draft = AppearanceSettings()
                    }
                    .controlSize(.small)
                    .disabled(draft.isDefault)

                    Spacer()

                    Text(draft.isDefault ? "当前为默认值" : "改动已保存")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            guard !isLoaded else { return }
            draft = app.appearance
            isLoaded = true
        }
        .onChange(of: draft) { _, newValue in
            guard isLoaded else { return }
            app.updateAppearance(newValue)
        }
    }

    // MARK: - 预览

    private var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("稀疏重复优于集中突击")
                    .font(.system(size: draft.headingSize(level: 3), weight: .semibold))
                    .fontDesign(design)

                (Text("集中突击可以短期记住更多，但")
                    + Text("[[遗忘曲线]]").foregroundStyle(Color.accentColor)
                    + Text("决定了长期留存。写完记得打上 ")
                    + Text("#记忆").foregroundStyle(.secondary))
                    .font(.system(size: draft.bodySize))
                    .fontDesign(design)
                    .lineSpacing(draft.lineSpacing)

                Text("let pattern = \"间隔重复\"")
                    .font(.system(size: draft.codeSize, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        } header: {
            Text("预览")
        }
    }

    private var design: Font.Design {
        switch draft.fontFamily {
        case .system: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}
