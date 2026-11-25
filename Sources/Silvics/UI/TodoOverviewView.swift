import SwiftUI

/// `⌘⇧T` 待办总览，占满中栏。
///
/// 跨全部日记聚合未完成的 `- [ ]`：同一句话取最近一天的状态，
/// 每行写清最早 / 最近出现与共几天。点一行跳到最近那天并滚动到那一行。
struct TodoOverviewView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if app.todoOverview.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("没有未完成的待办")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("在日记里写 `- [ ] 条目`，这里会跨天聚合。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(app.todoOverview) { todo in
                            row(todo)
                        }
                    }
                    .padding(6)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Text("点一行跳到「最近出现」那天，并选中那一行。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(app.todoOverview.count) 条")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("待办总览")
                .font(.system(size: 15, weight: .medium))
            Text("跨全部日记 · 取最近一天状态")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func row(_ todo: JournalTodo) -> some View {
        Button {
            app.jumpToTodo(todo)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(todo.detail)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text(todo.lastDate)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}
