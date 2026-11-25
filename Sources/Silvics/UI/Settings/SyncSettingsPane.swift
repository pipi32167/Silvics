import AppKit
import SwiftUI

/// 同步设置。备份 = vault 目录；同步 = 用 git 把它搬到别的机器。
struct SyncSettingsPane: View {
    @EnvironmentObject private var app: AppState

    @State private var draft = SyncSettings()
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var busy = false
    @State private var log: [String] = []
    @State private var probe: RemoteProbe.Outcome?
    @State private var isProbing = false

    var body: some View {
        Form {
            statusSection
            vaultSection
            remoteSection
            clipSection
            timingSection
            authorSection
            actionSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            guard !loaded else { return }
            draft = app.syncSettings
            loaded = true
        }
        .onChange(of: draft) { _, newValue in
            guard loaded else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { persist(newValue) }
            }
        }
        .onDisappear { persist(draft) }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section {
            LabeledContent("状态") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(draft.isReadyToSync ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(draft.isReadyToSync ? "已配置" : "未配置")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("上次同步") {
                Text(lastSyncedText).foregroundStyle(.secondary)
            }
            if !app.syncStatusLine.isEmpty {
                LabeledContent("最近一次") {
                    Text(app.syncStatusLine).foregroundStyle(.secondary)
                }
            }
            if !app.syncConflicts.isEmpty {
                Button {
                    app.isShowingConflicts = true
                } label: {
                    Label("\(app.syncConflicts.count) 处冲突待处理", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("状态")
        } footer: {
            Text("这些设置只存在本机。同步是你主动触发的：定时、失焦、或点按钮；不会因为改一个字就推送。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var lastSyncedText: String {
        // 用 app 里的，不用 draft：同步完成后 draft 是旧的副本。
        let stamp = app.syncSettings.lastSyncedAt
        guard stamp > 0 else { return "从未" }
        let date = Date(timeIntervalSince1970: Double(stamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - vault

    private var vaultSection: some View {
        Section {
            LabeledContent("位置") {
                HStack(spacing: 8) {
                    TextField("~/Documents/Silvics Vault", text: $draft.vaultPath)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    Button("选择…") { pickVaultDirectory() }
                        .controlSize(.small)
                    Button("默认") { draft.vaultPath = "" }
                        .controlSize(.small)
                        .disabled(draft.vaultPath.isEmpty)
                }
            }
        } header: {
            Text("vault 目录")
        } footer: {
            Text("笔记以 Markdown 纯文本写进这个目录。备份 = 这份目录本身。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 远端

    private var remoteSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField("git@github.com:you/vault.git", text: $draft.remoteURL)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                if let problem = draft.remoteURLProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            LabeledContent("分支") {
                TextField("", text: $draft.branch)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 160)
            }
            if let problem = draft.branchProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LabeledContent("SSH 私钥") {
                TextField("~/.ssh/id_ed25519", text: $draft.sshKeyPath)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                Button("测试连接") { runProbe() }
                    .controlSize(.small)
                    .disabled(isProbing || draft.remoteURL.isEmpty)
                if isProbing { ProgressView().controlSize(.small) }
                if let probe {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(probe.message)
                            if !probe.detail.isEmpty {
                                Text(probe.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    } icon: {
                        Image(systemName: probe.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(probe.ok ? Color.green : Color.orange)
                }
                Spacer()
            }
        } header: {
            Text("git 远端")
        } footer: {
            Text("远端要先是空仓库。可以在 GitHub 新建一个 private 仓库，再把地址粘到这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 时机

    private var clipSection: some View {
        Section {
            Toggle(isOn: $draft.syncClips) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同步剪藏")
                    Text("关掉后导出跳过 clips/，导入也不拉剪藏。已有文件保留在 vault 里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("剪藏") {
                Text("\(app.clipTotalCount) 条，\(draft.syncClips ? "已纳入同步" : "未纳入同步")")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("剪藏")
        }
    }

    private var timingSection: some View {
        Section {
            Toggle(isOn: $draft.backgroundSync) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("定时同步")
                    Text("按间隔做一次「拉 + 合并 + 推」。冲突时自动暂停，等你处理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            LabeledContent("间隔") {
                Picker("", selection: $draft.syncIntervalMinutes) {
                    ForEach(SyncSettings.allowedIntervals, id: \.self) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                .disabled(!draft.backgroundSync)
            }
        } header: {
            Text("同步时机")
        } footer: {
            Text("除此之外还会：启动 10 秒后拉一次；切到别的 App 后，若距上次超过 5 分钟再同步一次；退出前不做网络操作。失败后按 5 / 15 / 60 分钟退避。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 署名

    private var authorSection: some View {
        Section("提交署名") {
            LabeledContent("作者名") {
                TextField("", text: $draft.authorName)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 200)
            }
            LabeledContent("邮箱") {
                TextField("", text: $draft.authorEmail)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 200)
            }
        }
    }

    // MARK: - 动作

    private var actionSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("立即同步") { run { try $0.sync().summary } }
                    .controlSize(.small)
                    .disabled(busy || !draft.isReadyToSync)
                Button("从 vault 恢复") { runImport() }
                    .controlSize(.small)
                    .disabled(busy)
                Button("校验") { runVerify() }
                    .controlSize(.small)
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("打开目录") { openVault() }
                    .controlSize(.small)
            }

            if !log.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(log.prefix(6).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    // MARK: - 动作实现

    private func persist(_ value: SyncSettings) {
        var settings = value
        settings.sshKeyPath = settings.sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.branch = settings.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        app.saveSyncSettings(settings)
        app.rescheduleSync()
    }

    private func run(_ work: @escaping (VaultSync) throws -> String) {
        persist(draft)
        busy = true
        log = []
        app.performSyncWork { sync in
            [try work(sync)]
        } done: { lines in
            busy = false
            log = lines
            draft = app.syncSettings
        }
    }

    private func runVerify() {
        persist(draft)
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
        persist(draft)
        busy = true
        log = []
        app.performSyncWork { sync in
            let report = try sync.importAll()
            return ["恢复：新增 \(report.inserted)，更新 \(report.updated)，未变 \(report.unchanged)"]
                + report.titleConflicts
        } done: { lines in
            busy = false
            log = lines
        }
    }

    private func runProbe() {
        persist(draft)
        isProbing = true
        probe = nil
        let settings = draft
        Task {
            let outcome = await RemoteProbe.check(
                remoteURL: settings.remoteURL,
                sshKeyPath: settings.effectiveSSHKeyPath
            )
            await MainActor.run {
                isProbing = false
                probe = outcome
            }
        }
    }

    private func pickVaultDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选这个目录作为 vault"
        if panel.runModal() == .OK, let url = panel.url {
            draft.vaultPath = url.path
        }
    }

    private func openVault() {
        let url = draft.vaultURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
