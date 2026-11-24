import AppKit
import SwiftUI

/// 备份与同步面板。
struct SyncSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var settings: SyncSettings
    @State private var busy = false
    @State private var log: [String] = []

    init(settings: SyncSettings? = nil) {
        _settings = State(initialValue: settings ?? SyncSettings())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("备份与同步")
                    .font(.title2.weight(.semibold))
                Text("笔记以 Markdown 纯文本存进 vault 目录。备份 = 这份目录；同步 = 用 git 把它搬到别的机器。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                    group("vault 目录") {
                        row("位置") {
                            HStack(spacing: 8) {
                                TextField("默认 ~/Documents/Silvics Vault", text: $settings.vaultPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("选择…") { pickVaultDirectory() }
                                Button("默认") { settings.vaultPath = "" }
                            }
                        }
                    }

                    group("git 远端") {
                        row("地址") {
                            TextField("git@github.com:用户名/silvics-vault.git", text: $settings.remoteURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        row("分支") {
                            TextField("main", text: $settings.branch)
                                .textFieldStyle(.roundedBorder)
                        }
                        row("SSH 私钥") {
                            TextField("留空用 ~/.ssh/id_ed25519", text: $settings.sshKeyPath)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    group("提交署名") {
                        row("作者名") {
                            TextField("Silvics", text: $settings.authorName)
                                .textFieldStyle(.roundedBorder)
                        }
                        row("邮箱") {
                            TextField("silvics@localhost", text: $settings.authorEmail)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if !log.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(log.prefix(6).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            Color(nsColor: .textBackgroundColor).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
            }

            Divider()

            HStack(spacing: 10) {
                Button("立即同步") { run { try $0.sync().summary } }
                    .keyboardShortcut(.defaultAction)
                Button("从 vault 恢复") { runImport() }
                Button("校验") { runVerify() }
                if busy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("打开目录") { openVault() }
                Button("关闭") { dismiss() }
            }
            .disabled(busy)
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .onAppear {
            settings = app.syncSettings
        }
    }

    // MARK: - 小部件

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout)
                .frame(width: 76, alignment: .leading)
            content()
        }
    }

    // MARK: - 动作

    private func run(_ work: @escaping (VaultSync) throws -> String) {
        persist()
        busy = true
        log = []
        app.performSyncWork { sync in
            let summary = try work(sync)
            return [summary]
        } done: { lines in
            busy = false
            log = lines
            settings = app.syncSettings
        }
    }

    private func runVerify() {
        persist()
        busy = true
        log = []
        app.performSyncWork { sync in
            let result = try sync.verify()
            return [result.summary] + result.problems
        } done: { lines in
            busy = false
            log = lines
        }
    }

    private func runImport() {
        persist()
        busy = true
        log = []
        app.performSyncWork { sync in
            let report = try sync.importAll()
            return [
                "恢复：新增 \(report.inserted)，更新 \(report.updated)，未变 \(report.unchanged)",
            ] + report.titleConflicts
        } done: { lines in
            busy = false
            log = lines
        }
    }

    private func persist() {
        settings.sshKeyPath = settings.sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        app.saveSyncSettings(settings)
    }

    private func pickVaultDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选这个目录作为 vault"
        if panel.runModal() == .OK, let url = panel.url {
            settings.vaultPath = url.path
        }
    }

    private func openVault() {
        let url = settings.vaultURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private func timeText(_ ms: Int64) -> String {
        guard ms > 0 else { return "从未" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
