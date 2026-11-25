import SwiftUI

/// 日记模板管理面板（同一个「模板…」入口）。
///
/// 三件事都在这里：
/// - 列表：vault 里全部模板，按 order 排，显示名字、order 与正文首行摘要。
/// - 增删改：写 `templates/<名字>.md`，frontmatter 带 `template.name` / `template.order`。
/// - 勾选：下一次新建日记用哪些。记忆落 `JournalTemplateMemory`（UserDefaults）。
///
/// 只影响之后新建的日记，已有日记的正文一个字都不改。
struct JournalTemplateSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// 从磁盘读出来的模板，按 order 升序。保存后重新读，保证界面与文件一致。
    @State private var choices: [JournalTemplate] = []
    /// 勾选中的模板名，按 order 顺序落记忆。
    @State private var selected: Set<String> = []
    /// 非 nil 时显示表单（新建或编辑）。
    @State private var draft: Draft?
    @State private var errorText: String?
    @State private var pendingDelete: JournalTemplate?

    /// 表单里的三个字段。`original` 为 nil 表示新建。
    fileprivate struct Draft: Equatable {
        var original: JournalTemplate?
        var name: String
        var order: String
        var body: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let draft {
                form(draft)
            } else {
                list
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 540, height: 480)
        .onAppear {
            reloadChoices()
            selected = Set(app.journalTemplateNames())
            #if DEBUG
            applyDebugPrefill()
            #endif
        }
        .alert("删除模板「\(pendingDelete?.name ?? "")」？", isPresented: deleteAlertBinding) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("会删掉 templates/\(pendingDelete?.name ?? "").md。删掉之后这份模板就不能再用了。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("日记模板")
                .font(.system(size: 15, weight: .medium))
            Text(draft == nil ? "勾选决定下次新建；点铅笔改内容" : "正文会注入新日记的标题下面")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        if choices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("vault 里还没有模板")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("点下面的「新建模板」，正文会以 `## 名字` 加模板正文的形式出现在新日记里。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(choices) { template in
                        row(template)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func row(_ template: JournalTemplate) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: binding(for: template.name)) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("下次新建日记用这份模板")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(template.name)
                        .font(.system(size: 12))
                    Text(orderLabel(template.order))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(summary(of: template.body))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)

            Button {
                beginEdit(template)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("编辑「\(template.name)」")
            .accessibilityIdentifier("template-edit-\(template.name)")

            Button {
                pendingDelete = template
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("删除「\(template.name)」")
            .accessibilityIdentifier("template-delete-\(template.name)")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("编辑…") { beginEdit(template) }
            Button("删除…") { pendingDelete = template }
        }
    }

    // MARK: - 表单

    private func form(_ draft: Draft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("名字")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                TextField("工作", text: bind(\.name))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 220)
                Text("order")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("1", text: bind(\.order))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 60)
                Spacer(minLength: 0)
            }

            Text("正文（原样注入 `## 名字` 下面，空行会被规整）")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            TextEditor(text: bind(\.body))
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            Text(HintText.preview(draft))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 底部按钮

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft == nil {
                Text("已在日记里写下的正文不受影响：勾选只决定骨架，不重写历史。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if draft == nil {
                    Button("按 order 最小的前两个") {
                        selected = Set(app.defaultJournalTemplateNames())
                    }
                    .controlSize(.small)
                    .disabled(choices.isEmpty)

                    Button("新建模板") {
                        beginCreate()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("template-new")
                }

                Spacer()

                if draft == nil {
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)

                    Button("保存") {
                        app.setJournalTemplateNames(orderedSelection())
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                } else {
                    Button("取消编辑") {
                        draft = nil
                        errorText = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)

                    Button("保存模板") { commitDraft() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.small)
                        .accessibilityIdentifier("template-save")
                }
            }
        }
    }

    // MARK: - 动作

    private func reloadChoices() {
        choices = JournalTemplates.sorted(JournalTemplates.load(in: app.debugVaultURL))
    }

    private func beginCreate() {
        draft = Draft(original: nil, name: "", order: "\(suggestedOrder())", body: "")
        errorText = nil
    }

    private func beginEdit(_ template: JournalTemplate) {
        draft = Draft(
            original: template,
            name: template.name,
            order: orderText(template.order),
            body: JournalTemplates.normalizeBody(template.body)
        )
        errorText = nil
    }

    private func commitDraft() {
        guard let draft else { return }
        let wasSelected = draft.original.map { selected.contains($0.name) } ?? false
        do {
            let saved = try app.saveJournalTemplate(
                draft.original,
                name: draft.name,
                order: draft.order,
                body: draft.body
            )
            // 改名后勾选状态跟着走，不要因为换了名字就变成「没勾」。
            if wasSelected, let original = draft.original {
                selected.remove(original.name)
                selected.insert(saved.name)
            }
            self.draft = nil
            errorText = nil
            reloadChoices()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func confirmDelete() {
        guard let template = pendingDelete else { return }
        pendingDelete = nil
        do {
            try app.deleteJournalTemplate(template)
            selected.remove(template.name)
            if draft?.original?.path == template.path {
                draft = nil
            }
            errorText = nil
            reloadChoices()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - 绑定与文案

    private func bind(_ keyPath: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { value in
                draft?[keyPath: keyPath] = value
                errorText = nil
            }
        )
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

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func orderLabel(_ order: Int) -> String {
        order == JournalTemplates.unorderedOrder ? "order 未标注" : "order \(order)"
    }

    private func orderText(_ order: Int) -> String {
        order == JournalTemplates.unorderedOrder ? "1" : "\(order)"
    }

    /// 新建时的建议 order：已有最大 order + 1，没模板时从 1 起。
    private func suggestedOrder() -> Int {
        let orders = choices.map(\.order).filter { $0 != JournalTemplates.unorderedOrder }
        return (orders.max() ?? 0) + 1
    }

    /// 列表里的正文摘要：第一行非空内容，压掉多余空白后截断。
    private func summary(of body: String) -> String {
        let text = JournalTemplates.normalizeBody(body)
        guard !text.isEmpty else { return "（没有正文，只写标题）" }
        let first = text.components(separatedBy: "\n").first ?? ""
        let collapsed = first.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return collapsed.count > 34 ? String(collapsed.prefix(34)) + "…" : collapsed
    }

    #if DEBUG
    /// 仅用于取证：`SILVICS_TEMPLATE_DRAFT="name|order|第一行;第二行"` 预填新建表单；
    /// `SILVICS_TEMPLATE_EDIT=<名字>` 直接打开某份模板的编辑表单。
    private func applyDebugPrefill() {
        let env = ProcessInfo.processInfo.environment
        if let spec = env["SILVICS_TEMPLATE_DRAFT"], !spec.isEmpty {
            let parts = spec.components(separatedBy: "|")
            draft = Draft(
                original: nil,
                name: parts.first ?? "",
                order: parts.count > 1 ? parts[1] : "\(suggestedOrder())",
                body: parts.count > 2 ? parts[2].replacingOccurrences(of: ";", with: "\n") : ""
            )
            return
        }
        if let name = env["SILVICS_TEMPLATE_EDIT"], !name.isEmpty,
           let template = choices.first(where: { $0.name == name }) {
            beginEdit(template)
        }
    }
    #endif
}

/// 表单下方的骨架预览。独立出来只为让 `form` 少一层缩进。
private enum HintText {
    static func preview(_ draft: JournalTemplateSheet.Draft) -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = JournalTemplates.normalizeBody(draft.body)
        let title = name.isEmpty ? "## （名字）" : "## \(name)"
        guard !body.isEmpty else { return "预览：\(title)" }
        return "预览：\(title) ⏎ \(body.components(separatedBy: "\n").first ?? "")"
    }
}
