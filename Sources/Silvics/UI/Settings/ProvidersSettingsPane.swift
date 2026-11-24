import AppKit
import SwiftUI

/// 模型服务设置：用途绑定、服务商列表、编辑表单、测试连接、导入导出。
struct ProvidersSettingsPane: View {
    @EnvironmentObject private var app: AppState

    @State private var selectedId: UUID?
    @State private var draft: ProviderConfig?
    @State private var secretInput = ""
    @State private var errors: [String] = []
    @State private var notice: String?
    @State private var testResult: ProbeResult?
    @State private var isTesting = false
    @State private var testRole: ProviderRole = .chat
    @State private var isConfirmingReset = false
    @State private var models: [ProviderModel] = []
    @State private var modelFilter = ""
    @State private var isLoadingModels = false
    @State private var modelsError: String?

    private var providers: [ProviderConfig] { app.providerSettings.providers }

    var body: some View {
        Form {
            bindingSection

            Section {
                if providers.isEmpty {
                    Text("还没有服务商。用下方「添加服务商」挑一个预设，或选自定义。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(providers) { provider in
                        providerRow(provider)
                    }
                }

                Menu("添加服务商") {
                    ForEach(ProviderPresets.all) { preset in
                        Button(preset.isCustom ? "自定义…" : preset.name) {
                            add(preset)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
            } header: {
                Text("服务商")
            } footer: {
                Text("预设只带服务地址与默认模型名。改动预设会另存为自定义服务，不覆盖预设。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if draft != nil {
                editorSection
            }

            transferSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            app.refreshProviders()
            if selectedId == nil, let first = providers.first {
                select(first)
            }
        }
        .confirmationDialog(
            "恢复全部设置？",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("恢复全部设置", role: .destructive) {
                app.resetAllSettings()
                draft = nil
                selectedId = nil
                notice = "已恢复全部设置。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清空外观设置、全部服务商与钥匙串里的密钥。笔记不受影响。")
        }
    }

    // MARK: - 用途绑定

    private var bindingSection: some View {
        Section {
            ForEach(ProviderRole.allCases) { role in
                VStack(alignment: .leading, spacing: 4) {
                    Picker(role.title, selection: binding(for: role)) {
                        Text("未选择").tag(UUID?.none)
                        ForEach(candidates(for: role)) { provider in
                            Text(provider.name).tag(UUID?.some(provider.id))
                        }
                    }
                    .pickerStyle(.menu)

                    if let reason = app.providerService.unavailableReason(role) {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(role.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("用途")
        } footer: {
            Text("未配置的服务对应功能保持不可用：L4 需要向量模型，L3 需要对话模型。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for role: ProviderRole) -> Binding<UUID?> {
        Binding(
            get: {
                switch role {
                case .chat: return app.providerSettings.chatProviderId
                case .embedding: return app.providerSettings.embeddingProviderId
                }
            },
            set: { app.bindProvider(role, to: $0) }
        )
    }

    private func candidates(for role: ProviderRole) -> [ProviderConfig] {
        providers.filter { role == .chat ? $0.providesChat : $0.providesEmbedding }
    }

    // MARK: - 列表

    private func providerRow(_ provider: ProviderConfig) -> some View {
        let isSelected = provider.id == selectedId
        return Button {
            select(provider)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(.system(size: 12.5, weight: .medium))
                        Text(provider.kind.title)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if !provider.enabled {
                            Text("已停用").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    HStack(spacing: 8) {
                        if provider.providesChat {
                            badge("对话 \(provider.chatModel)")
                        }
                        if provider.providesEmbedding {
                            badge("向量 \(provider.embeddingModel)")
                        }
                    }
                }

                Spacer()

                if app.hasKey(for: provider.id) {
                    Label("已配置密钥", systemImage: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label("缺密钥", systemImage: "key.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
    }

    // MARK: - 编辑

    @ViewBuilder
    private var editorSection: some View {
        if let draftBinding = Binding($draft) {
            Section {
                TextField("名称", text: draftBinding.name)

                Picker("协议", selection: draftBinding.kind) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("服务地址") {
                    TextField("https://…", text: draftBinding.baseURL)
                        .labelsHidden()
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 8) {
                    Button("拉取模型列表") { loadModels(for: draftBinding.wrappedValue) }
                        .controlSize(.small)
                        .disabled(isLoadingModels)
                    if isLoadingModels { ProgressView().controlSize(.small) }
                    if !models.isEmpty {
                        Text("\(models.count) 个模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let modelsError {
                    Label(modelsError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !models.isEmpty {
                    TextField("筛选模型", text: $modelFilter)
                        .font(.system(size: 12))

                    Picker("从列表选择对话模型", selection: draftBinding.chatModel) {
                        ForEach(filteredModels) { model in
                            Text(model.label == model.id ? model.id : "\(model.label) — \(model.id)")
                                .tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                TextField("对话模型名", text: draftBinding.chatModel)
                TextField("向量模型名（可留空）", text: draftBinding.embeddingModel)
                    .disabled(draftBinding.wrappedValue.kind == .anthropic)

                if draftBinding.wrappedValue.requiresKey {
                    SecureField(
                        app.hasKey(for: draftBinding.wrappedValue.id)
                            ? "密钥已保存（重新输入可覆盖）"
                            : "API Key",
                        text: $secretInput
                    )
                } else {
                    Label("本地服务，不需要密钥", systemImage: "lock.open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("启用", isOn: draftBinding.enabled)

                if !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("保存") { save() }
                        .controlSize(.small)
                    Button("测试连接") { test(config: draftBinding.wrappedValue) }
                        .controlSize(.small)
                        .disabled(isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }

                    Spacer()

                    Button("删除", role: .destructive) {
                        remove(draftBinding.wrappedValue.id)
                    }
                    .controlSize(.small)
                }

                if let testResult {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(testResult.message) · \(testResult.latencyMs) ms")
                            if !testResult.detail.isEmpty {
                                Text(testResult.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(testResult.ok ? Color.green : Color.orange)
                }

                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("编辑")
            } footer: {
                Text("密钥只存钥匙串，本机数据库与设置文件里只有引用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 导入导出

    private var transferSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("导出配置…") { exportConfig() }
                    .controlSize(.small)
                    .disabled(providers.isEmpty)

                Button("导入配置…") { importConfig() }
                    .controlSize(.small)

                Spacer()

                Button("恢复全部设置") { isConfirmingReset = true }
                    .controlSize(.small)
                    .tint(.red)
            }
        } header: {
            Text("备份")
        } footer: {
            Text("导出的 JSON 不含密钥。换机器后导入配置，再重新填一次 key。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var filteredModels: [ProviderModel] {
        let key = modelFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return models }
        return models.filter {
            $0.id.lowercased().contains(key) || $0.label.lowercased().contains(key)
        }
    }

    private func loadModels(for config: ProviderConfig) {
        guard let base = config.normalizedBaseURL else {
            modelsError = "先把服务地址填对"
            return
        }
        isLoadingModels = true
        modelsError = nil
        let key = app.providerService.secret(for: config.id) ?? ""
        Task {
            let result = await ProviderModels.fetch(baseURL: base, key: key)
            await MainActor.run {
                isLoadingModels = false
                switch result {
                case .success(let list):
                    models = list
                    modelFilter = ""
                    if list.count == 1 { draft?.chatModel = list[0].id }
                case .failure(let failure):
                    models = []
                    modelsError = failure.text
                }
            }
        }
    }

    // MARK: - 动作

    private func select(_ provider: ProviderConfig) {
        selectedId = provider.id
        draft = provider
        secretInput = ""
        errors = []
        testResult = nil
        notice = nil
        models = []
        modelFilter = ""
        modelsError = nil
    }

    private func add(_ preset: ProviderPreset) {
        var config = preset.config()
        config.name = uniqueName(preset.name)
        draft = config
        selectedId = config.id
        secretInput = ""
        errors = []
        testResult = nil
        notice = preset.isCustom ? "填好服务地址与模型名，保存后会出现在列表里。" : nil
    }

    private func uniqueName(_ base: String) -> String {
        let existing = Set(providers.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func save() {
        guard let config = draft else { return }
        let errors = app.saveProvider(config, secret: secretInput.isEmpty ? nil : secretInput)
        self.errors = errors
        if errors.isEmpty {
            secretInput = ""
            notice = "已保存。"
            testResult = nil
        }
    }

    private func remove(_ id: UUID) {
        app.deleteProvider(id)
        draft = nil
        selectedId = nil
        notice = "已删除，并清掉对应密钥。"
        testResult = nil
    }

    private func test(config: ProviderConfig) {
        // 未保存的改动先存，否则测的还是旧配置。
        if !app.providerSettings.providers.contains(where: { $0.id == config.id }) {
            let errors = app.saveProvider(config, secret: secretInput.isEmpty ? nil : secretInput)
            if !errors.isEmpty { self.errors = errors; return }
        } else if !secretInput.isEmpty {
            app.saveProvider(config, secret: secretInput)
        }
        isTesting = true
        testResult = nil
        Task {
            let role: ProviderRole = config.providesChat ? .chat : .embedding
            let result = await app.testProvider(config.id, role: role)
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }

    private func exportConfig() {
        guard let data = app.exportProviderConfig() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "silvics-providers.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            notice = "已导出到 \(url.lastPathComponent)（不含密钥）。"
        } catch {
            errors = ["导出失败：\(error.localizedDescription)"]
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let messages = app.importProviderConfig(data)
        errors = []
        notice = messages.isEmpty ? "已导入配置，记得重新填密钥。" : messages.joined(separator: "；")
        if selectedId == nil, let first = providers.first { select(first) }
    }
}
