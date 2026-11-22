import SwiftUI

/// 未链接提及的批量整理。
///
/// 流程固定三步：选择 → 看 diff → 转换。
/// 转换是不可逆的正文改动（有撤销，但先看 diff 是设计文档 5.3 的硬要求）。
struct MentionSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case select
        case preview
        case done
    }

    @State private var phase: Phase = .select
    @State private var selectedTargets: Set<String> = []
    @State private var previews: [NoteConversion] = []
    @State private var converted = 0

    private var groups: [MentionGroup] { app.mentionGroups }

    private var selectedOccurrenceIds: [Int64] {
        groups.filter { selectedTargets.contains($0.targetId) }.flatMap { $0.occurrences.map(\.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            switch phase {
            case .select: selectList
            case .preview: previewList
            case .done: doneView
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .onAppear { app.refreshMentionGroups() }
    }

    // MARK: - 头尾

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("未链接提及")
                .font(.system(size: 15, weight: .semibold))
            Text("\(groups.reduce(0) { $0 + $1.count }) 处 / \(groups.count) 个目标")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if phase == .select, !groups.isEmpty {
                Button("全选") { selectedTargets = Set(groups.map(\.targetId)) }
                    .buttonStyle(.link)
                Button("清空") { selectedTargets.removeAll() }
                    .buttonStyle(.link)
            }
        }
    }

    private var footer: some View {
        HStack {
            if phase == .select {
                Button("全部转换…") {
                    selectedTargets = Set(groups.map(\.targetId))
                    makePreview()
                }
                .buttonStyle(.link)
            }
            Spacer()
            switch phase {
            case .select:
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下一步：看 diff") { makePreview() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedOccurrenceIds.isEmpty)
            case .preview:
                Button("返回") { phase = .select }
                Button("确认转换") { commit() }
                    .keyboardShortcut(.defaultAction)
            case .done:
                if app.canUndoConversion {
                    Button("撤销这次转换") {
                        app.undoLastConversion()
                        phase = .select
                        app.refreshMentionGroups()
                    }
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - 选择

    private var selectList: some View {
        Group {
            if groups.isEmpty {
                emptyState("没有未链接提及。正文里写到已有标题时，这里会出现。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groups) { group in
                            groupRow(group)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func groupRow(_ group: MentionGroup) -> some View {
        let isOn = selectedTargets.contains(group.targetId)
        return Button {
            if isOn { selectedTargets.remove(group.targetId) } else { selectedTargets.insert(group.targetId) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(group.targetTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                        Text("\(group.count) 处 · \(group.noteCount) 篇")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                        if group.occurrences.contains(where: { $0.kind == .partial }) {
                            Text("模糊匹配")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    ForEach(group.occurrences.prefix(2)) { occurrence in
                        Text(occurrence.snippet)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isOn ? 0.075 : 0.04))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Diff

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("转换会插入 \(previews.reduce(0) { $0 + $1.insertedCount }) 个引用，改动 \(previews.count) 篇笔记的正文。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(previews) { conversion in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(conversion.note.title)
                                .font(.system(size: 11.5, weight: .semibold))
                            ForEach(Array(LineDiff.changes(old: conversion.previousBody, new: conversion.note.body).enumerated()), id: \.offset) { _, change in
                                VStack(alignment: .leading, spacing: 2) {
                                    if let old = change.oldLine {
                                        diffLine(old, tone: .removed)
                                    }
                                    if let new = change.newLine {
                                        diffLine(new, tone: .added)
                                    }
                                }
                            }
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
            }
        }
    }

    private enum DiffTone { case added, removed }

    private func diffLine(_ text: String, tone: DiffTone) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(tone == .added ? "+" : "−")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tone == .added ? Color.green : Color.red)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tone == .added ? Color.primary : Color.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tone == .added ? Color.green.opacity(0.10) : Color.red.opacity(0.07))
        )
    }

    // MARK: - 完成

    private var doneView: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("已转换 \(converted) 处提及。")
                .font(.system(size: 12.5))
            Text("需要还原可按「撤销这次转换」，或用菜单「编辑 → 撤销上次批量转换」。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 动作

    private func makePreview() {
        let ids = selectedOccurrenceIds
        guard !ids.isEmpty else { return }
        previews = app.previewMentionConversion(ids: ids)
        phase = previews.isEmpty ? .select : .preview
    }

    private func commit() {
        let inserted = previews.reduce(0) { $0 + $1.insertedCount }
        if app.convertMentions(ids: selectedOccurrenceIds) {
            converted = inserted
            phase = .done
            app.refreshMentionGroups()
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.quaternary)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
