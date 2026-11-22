import SwiftUI

/// `⌘P` Quick Open。只按标题找，不做全文搜索（全文在侧栏搜索框）。
struct QuickOpenSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var items: [QuickOpenItem] = []
    @State private var selected: Int = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                TextField("按标题打开笔记", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit { activate(selected) }
                    .onChange(of: query) { _, _ in reload() }
                    .onKeyPress(.downArrow) {
                        move(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(-1)
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if items.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "没有笔记" : "没有匹配的标题")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == selected)
                                    .id(index)
                                    .onTapGesture { activate(index) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selected) { _, newValue in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
                .frame(height: 280)
            }

            Divider()

            HStack(spacing: 10) {
                hint("↑↓", "选择")
                hint("↩", "打开")
                hint("esc", "关闭")
                Spacer()
                Text("\(items.count) 项")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(width: 560)
        .onAppear {
            reload()
            fieldFocused = true
        }
    }

    private func row(_ item: QuickOpenItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.status.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(item.status == .evergreen ? Color.accentColor : Color.secondary)

            Text(item.title)
                .font(.system(size: 12.5))
                .lineLimit(1)

            if !item.tags.isEmpty {
                Text(item.tags.map { "#" + $0 }.joined(separator: " "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if item.backlinkCount > 0 {
                Text("\(item.backlinkCount) ←")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .medium).monospaced())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func reload() {
        items = app.quickOpenItems(query: query)
        selected = items.isEmpty ? 0 : min(selected, items.count - 1)
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = max(0, min(items.count - 1, selected + delta))
    }

    private func activate(_ index: Int) {
        guard items.indices.contains(index) else { return }
        app.select(items[index].id)
        dismiss()
    }
}
