import AppKit
import SwiftUI

/// 关于页：版本、数据目录、链接，以及重置入口。
struct AboutSettingsPane: View {
    @EnvironmentObject private var app: AppState

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private var dataDirectory: URL? {
        try? AppDatabase.defaultDirectory()
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Silvics")
                            .font(.largeTitle.bold())
                        Text("版本 \(version)（\(build)）")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("笔记需要培育，不需要归档。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("数据") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("数据库目录")
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                            .padding(.top, 2)
                        Text(dataDirectory?.path ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 8) {
                    Button("在 Finder 中显示") {
                        guard let dataDirectory else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([dataDirectory])
                    }
                    .controlSize(.small)
                    .disabled(dataDirectory == nil)

                    Button("立即保存当前笔记") {
                        app.flushPendingSave()
                    }
                    .controlSize(.small)
                }
            }

            Section("项目") {
                Link("GitHub 仓库", destination: URL(string: "https://github.com/pipi32167/Silvics")!)
                Link("最新版本", destination: URL(string: "https://github.com/pipi32167/Silvics/releases/latest")!)
                Text("Markdown 纯文本 + [[引用]] + 自动生成连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("恢复外观默认") {
                    app.resetAppearance()
                }
                .controlSize(.small)
                .disabled(app.appearance.isDefault)

                Text("只重置字号、行距与字体族，不动笔记与其它设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("重置")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
