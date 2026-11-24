import SwiftUI

/// 同步冲突处理。两份正文都改了，diff3 合不了，交给模型合，再人工确认。
struct ConflictSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedId: String?
    @State private var merged: String?
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var statusLine: String?

    private var conflicts: [VaultConflict] { app.syncConflicts }

    private var selected: VaultConflict? {
        conflicts.first { $0.noteId == selectedId } ?? conflicts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            if conflicts.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 12) {
                    list.frame(width: 210)
                    Divider()
                    detail
                }
                .frame(maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .padding(18)
        .frame(width: 900, height: 620)
        .onAppear {
            if selectedId == nil { selectedId = conflicts.first?.noteId }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("同步冲突")
                .font(.system(size: 15, weight: .semibold))
            Text("\(conflicts.count) 处")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if let statusLine {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(conflicts) { conflict in
                    Button {
                        selectedId = conflict.noteId
                        merged = nil
                        errorMessage = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conflict.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(conflict.sizeHint)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(conflict.noteId == (selected?.noteId) ? 0.09 : 0.035))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let conflict = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("本机版本", text: conflict.ours, tone: .plain)
                    section("远端版本", text: conflict.theirs, tone: .plain)

                    if let merged {
                        section("合并结果（待确认）", text: merged, tone: .merged)
                        diffView(conflict: conflict, merged: merged)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.bottom, 8)
            }
        } else {
            Text("没有冲突")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private enum Tone { case plain, merged }

    private func section(_ title: String, text: String, tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "（空）" : text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tone == .merged ? Color.green.opacity(0.09) : Color.primary.opacity(0.04))
                )
        }
    }

    private func diffView(conflict: VaultConflict, merged: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("相对本机的改动")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            ForEach(Array(LineDiff.changes(old: conflict.ours, new: merged).enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 1) {
                    if let old = change.oldLine {
                        Text("− " + old)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.06))
                    }
                    if let new = change.newLine {
                        Text("+ " + new)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("全部用 LLM 合并") { resolveAll() }
                .controlSize(.small)
                .disabled(isResolving || conflicts.isEmpty)

            Spacer()

            if isResolving { ProgressView().controlSize(.small) }

            Button("用 LLM 合并这篇") { resolveSelected() }
                .controlSize(.small)
                .disabled(isResolving || selected == nil)

            Button("采用结果") { applyMerged() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(merged == nil)

            Button("关闭") { dismiss() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("没有待处理的冲突")
                .font(.system(size: 12))
            Text("自动合并能处理的都不会出现在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    private func resolveSelected() {
        guard let conflict = selected else { return }
        isResolving = true
        errorMessage = nil
        Task {
            let result = await app.resolveConflictWithLLM(conflict)
            await MainActor.run {
                isResolving = false
                switch result {
                case .success(let text):
                    merged = text
                    statusLine = "已生成合并结果，确认后采用"
                case .failure(let error):
                    errorMessage = error.message
                }
            }
        }
    }

    private func resolveAll() {
        guard !conflicts.isEmpty else { return }
        isResolving = true
        errorMessage = nil
        Task {
            var done = 0
            var failures: [String] = []
            for conflict in conflicts {
                let result = await app.resolveConflictWithLLM(conflict)
                switch result {
                case .success(let text):
                    if let error = app.applyConflictResolution(conflict, body: text) {
                        failures.append("《\(conflict.title)》\(error)")
                    } else {
                        done += 1
                    }
                case .failure(let error):
                    failures.append("《\(conflict.title)》\(error.message)")
                }
            }
            await MainActor.run {
                isResolving = false
                merged = nil
                selectedId = app.syncConflicts.first?.noteId
                statusLine = "已合并 \(done) 篇" + (failures.isEmpty ? "" : "，失败 \(failures.count) 篇")
                if !failures.isEmpty {
                    errorMessage = failures.joined(separator: "；")
                }
            }
        }
    }

    private func applyMerged() {
        guard let conflict = selected, let merged else { return }
        if let error = app.applyConflictResolution(conflict, body: merged) {
            errorMessage = error
            return
        }
        self.merged = nil
        statusLine = "已采用合并结果"
        selectedId = app.syncConflicts.first?.noteId
    }
}
