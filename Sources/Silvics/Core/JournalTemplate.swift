import Foundation

/// 一份日记模板。vault 里一个文件：`templates/<名字>.md`。
///
/// frontmatter 用 `template:` 段给名字与顺序，沿用 `VaultFormat.parse`，不新造格式：
///
/// ```yaml
/// ---
/// template:
///   name: 工作
///   order: 1
/// ---
/// ```
struct JournalTemplate: Equatable, Sendable {
    /// 段名。`template.name` 缺省时取文件名。
    var name: String
    /// 拼接顺序。`template.order` 缺省或不是数字时排在最后。
    var order: Int
    /// vault 内的相对路径，给报错与排查用。
    var path: String
}

enum JournalTemplates {

    /// 没有显式 order 的模板排在这里。同值按名字排，保证结果与目录列举顺序无关。
    static let unorderedOrder = Int.max

    /// 读 `templates/*.md`。目录不存在、文件解析失败、没有 `template:` 段的都跳过，不抛错。
    static func load(in vaultURL: URL) -> [JournalTemplate] {
        let dir = vaultURL.appendingPathComponent(VaultFormat.templatesDir, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var templates: [JournalTemplate] = []
        for name in names.sorted() where name.hasSuffix(".md") {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let frontmatter = try? VaultFormat.parse(text) else { continue }
            let section = frontmatter.section("template")
            let fallbackName = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
            let templateName = (section?["name"]?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
            let order = section?["order"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? unorderedOrder
            templates.append(JournalTemplate(
                name: templateName,
                order: order,
                path: "\(VaultFormat.templatesDir)/\(name)"
            ))
        }
        return templates
    }

    /// 按 order 升序拼骨架：每段 `## <名字>`，段间一个空行。
    ///
    /// 点名但文件缺失的模板直接跳过（不报错，也不在正文里留空标题）。
    /// 名字重复时只取第一份。
    static func skeleton(named names: [String], in vaultURL: URL) -> String {
        guard !names.isEmpty else { return "" }
        let templates = load(in: vaultURL)
        var byName: [String: JournalTemplate] = [:]
        for template in templates where byName[template.name] == nil {
            byName[template.name] = template
        }

        var picked: [JournalTemplate] = []
        var seen = Set<String>()
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            guard let template = byName[name] else { continue }
            picked.append(template)
        }

        picked.sort { a, b in
            if a.order != b.order { return a.order < b.order }
            return a.name < b.name
        }
        return picked.map { "## \($0.name)\n" }.joined(separator: "\n")
    }
}
