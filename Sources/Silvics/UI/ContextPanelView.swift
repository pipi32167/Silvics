import SwiftUI

/// 右侧上下文面板：反向链接、出链、悬空目标。
/// 反向链接带原文上下文片段——这是 Matuschak 站点的做法，比纯标题列表有用。
struct ContextPanelView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if app.current == nil {
                    Text("选一条笔记查看连接")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                } else {
                    backlinkSection
                    mentionSection
                    outgoingSection
                    danglingSection
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("连接")
    }

    // MARK: - 反向链接

    private var backlinkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("反向链接", count: app.backlinks.count)

            if app.backlinks.isEmpty {
                hint("还没有笔记引用这一条。写在别的笔记里用 [[标题]] 即可。")
            } else {
                ForEach(app.backlinks) { backlink in
                    Button {
                        app.select(backlink.sourceId)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backlink.sourceTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(backlink.snippet)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 出链

    private var outgoingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("引用出去", count: app.outgoing.count)

            if app.outgoing.isEmpty {
                hint("这一条还没有引用别的笔记。输入 [[ 会弹出补全。")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(app.outgoing.enumerated()), id: \.offset) { _, link in
                        Button {
                            app.openTitle(link.rawTarget)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: link.status == .resolved ? "arrow.up.right" : "questionmark.circle.dashed")
                                    .font(.system(size: 9))
                                    .foregroundStyle(link.status == .resolved ? Color.accentColor : Color.secondary)
                                Text(link.displayText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(link.status == .resolved ? .primary : .secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 未链接提及

    private var mentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("未链接提及")
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text("\(app.mentions.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                if !app.mentions.isEmpty {
                    Button("整理") {
                        app.refreshMentionGroups()
                        app.isShowingMentionsSheet = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                }
            }

            if app.mentions.isEmpty {
                hint("正文里写到已有标题时，这里会出现。点中带点状下划线的文字按 ⌘⇧K 可转成引用。")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.mentions) { mention in
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: mention.kind == .alias ? "tag" : "link")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(nsColor: Theme.mentionUnderline))
                                .padding(.top, 3)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mention.targetTitle)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Text(mention.snippet)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer(minLength: 0)

                            Button {
                                app.select(mention.noteId)
                            } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("回到这篇笔记")

                            Button {
                                app.dismissMention(id: mention.id)
                            } label: {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("忽略这条提及")
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: - 悬空

    private var danglingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("悬空引用", count: app.danglingTargets.count)
            if app.danglingTargets.isEmpty {
                hint("没有指向不存在笔记的引用。")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(app.danglingTargets, id: \.self) { target in
                        Button {
                            _ = app.createIfNeeded(title: target)
                            app.loadAll()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus.circle.dashed")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(target)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("按这个标题新建一条笔记")
                    }
                }
            }
        }
    }

    // MARK: - 组件

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
