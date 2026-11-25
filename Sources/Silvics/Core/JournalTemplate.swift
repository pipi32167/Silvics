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
/// - [ ] 写批次 7 的测试
/// ```
///
/// `---` 之后的正文会在新建日记时原样注入骨架（`skeleton(named:in:)`）。
struct JournalTemplate: Equatable, Sendable, Identifiable {
    /// 段名。`template.name` 缺省时取文件名。
    var name: String
    /// 拼接顺序。`template.order` 缺省或不是数字时排在最后。
    var order: Int
    /// vault 内的相对路径，给报错与排查用。也是列表的唯一标识（名字会改，路径跟着改）。
    var path: String
    /// 正文。骨架里原样注入；空字符串表示这份模板只有标题。
    var body: String = ""

    /// `ForEach` 用的稳定标识。与 `name` 不同：改名时路径同时变，但同一时刻不会撞。
    var id: String { path }
}

enum JournalTemplates {

    /// 没有显式 order 的模板排在这里。同值按名字排，保证结果与目录列举顺序无关。
    static let unorderedOrder = Int.max

    /// 模板文件内容不合规。面板直接把 `errorDescription` 显示给人看，不吞错。
    enum TemplateError: LocalizedError, Equatable {
        /// 名字去掉首尾空白后是空的。
        case emptyName
        /// 名字里有 `/`：会被当成目录分隔符，落到 `templates/` 之外。
        case nameHasSlash(String)
        /// 已经有同名模板（按 `template.name` 或文件名比较）。
        case duplicateName(String)
        /// order 不是整数。
        case orderNotNumber(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "模板名不能为空。"
            case .nameHasSlash(let name):
                return "模板名不能含「/」：\(name)"
            case .duplicateName(let name):
                return "已经有名为「\(name)」的模板了，换个名字。"
            case .orderNotNumber(let raw):
                return "order 要填整数，现在填的是「\(raw)」。"
            }
        }
    }

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
                path: "\(VaultFormat.templatesDir)/\(name)",
                body: frontmatter.body
            ))
        }
        return templates
    }

    /// 按 order 升序，同 order 按名字。列表与骨架共用这一份排序口径。
    static func sorted(_ templates: [JournalTemplate]) -> [JournalTemplate] {
        templates.sorted { a, b in a.order != b.order ? a.order < b.order : a.name < b.name }
    }

    /// 新建日记默认用的模板：order 最小的前 `limit` 个（同 order 按名字）。
    /// 目录里没有模板时返回空数组，调用方拿到的骨架就是空字符串。
    static func defaultNames(in vaultURL: URL, limit: Int = 2) -> [String] {
        sorted(load(in: vaultURL))
            .prefix(limit)
            .map(\.name)
    }

    /// 新建日记实际要用的模板名：记忆优先，失效退回默认。
    ///
    /// - 记忆里按当前模板的 order 排序（不是记住时的顺序）。
    /// - 模板文件已被删掉的跳过；重名只取第一次出现。
    /// - 一个都不剩时退回 `defaultNames`（order 最小的前 `limit` 个）。
    static func newJournalNames(
        in vaultURL: URL,
        remembered: [String] = JournalTemplateMemory.names,
        limit: Int = 2
    ) -> [String] {
        let byName = templatesByName(in: vaultURL)
        var picked: [JournalTemplate] = []
        var seen = Set<String>()
        for raw in remembered {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            guard let template = byName[name] else { continue }
            picked.append(template)
        }
        guard !picked.isEmpty else { return defaultNames(in: vaultURL, limit: limit) }
        return sorted(picked).map(\.name)
    }

    /// 名字 → 模板。重名只取第一份，与 `skeleton` 的口径一致。
    private static func templatesByName(in vaultURL: URL) -> [String: JournalTemplate] {
        var byName: [String: JournalTemplate] = [:]
        for template in load(in: vaultURL) where byName[template.name] == nil {
            byName[template.name] = template
        }
        return byName
    }

    /// 按 order 升序拼骨架：每段 `## <名字>`，有正文就紧跟在标题下一行。
    ///
    /// 段与段之间恰好一个空行；模板没有正文时只有标题，不多出空行。
    /// 正文里的 `- [ ]` 原样保留（承接逻辑按行扫，不能改写）。
    ///
    /// 点名但文件缺失的模板直接跳过（不报错，也不在正文里留空标题）。
    /// 名字重复时只取第一份。
    static func skeleton(named names: [String], in vaultURL: URL) -> String {
        guard !names.isEmpty else { return "" }
        let byName = templatesByName(in: vaultURL)

        var picked: [JournalTemplate] = []
        var seen = Set<String>()
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            guard let template = byName[name] else { continue }
            picked.append(template)
        }

        let sections = sorted(picked).map { template -> String in
            let body = normalizeBody(template.body)
            return body.isEmpty ? "## \(template.name)\n" : "## \(template.name)\n\(body)\n"
        }
        return sections.joined(separator: "\n")
    }

    /// 正文规整：裁掉前后空行，段与段之间只留一个空行，其余行原样。
    ///
    /// 只动「空行」：不改缩进、不补标点、不碰列表前缀，`- [ ]` 一定原样留着。
    static func normalizeBody(_ raw: String) -> String {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var blankPending = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // 文首的空行直接丢；中间的先记着，等下一行真的来了再补一个。
                if !out.isEmpty { blankPending = true }
                continue
            }
            if blankPending {
                out.append("")
                blankPending = false
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 面板里的增删改

    /// 模板文件名。名字已经过校验（非空、不含 `/`）。
    static func fileName(for name: String) -> String { "\(name).md" }

    /// 模板文件的完整内容。同样输入必得同样字节，方便 git 里看 diff。
    static func encode(name: String, order: Int, body: String) -> String {
        var lines = ["---", "template:", "  name: \(name)", "  order: \(order)", "---"]
        let normalized = normalizeBody(body)
        if !normalized.isEmpty { lines.append(normalized) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 名字校验：去首尾空白后不能空，不能含 `/`。
    static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TemplateError.emptyName }
        guard !name.contains("/") else { throw TemplateError.nameHasSlash(name) }
        return name
    }

    /// order 校验：必须是整数。空字符串和「一」都算不合法，由面板提示重填。
    static func validatedOrder(_ raw: String) throws -> Int {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text) else { throw TemplateError.orderNotNumber(raw) }
        return value
    }

    /// 重名检查。`excluding` 是正在编辑的那份，改名后仍算它自己。
    static func ensureUnique(name: String, in vaultURL: URL, excluding: JournalTemplate?) throws {
        let excludedPath = excluding?.path
        for template in load(in: vaultURL) where template.path != excludedPath {
            if template.name == name || template.path == "\(VaultFormat.templatesDir)/\(fileName(for: name))" {
                throw TemplateError.duplicateName(name)
            }
        }
    }

    /// 新建模板：写 `templates/<名字>.md`，frontmatter 带 `template.name` / `template.order`。
    @discardableResult
    static func create(
        name rawName: String,
        order rawOrder: String,
        body: String,
        in vaultURL: URL
    ) throws -> JournalTemplate {
        let name = try validatedName(rawName)
        let order = try validatedOrder(rawOrder)
        try ensureUnique(name: name, in: vaultURL, excluding: nil)
        let fileName = fileName(for: name)
        let url = vaultURL
            .appendingPathComponent(VaultFormat.templatesDir, isDirectory: true)
            .appendingPathComponent(fileName)
        try VaultFormat.writeAtomic(Data(encode(name: name, order: order, body: body).utf8), to: url)
        return JournalTemplate(
            name: name,
            order: order,
            path: "\(VaultFormat.templatesDir)/\(fileName)",
            body: normalizeBody(body)
        )
    }

    /// 编辑模板。改名时先写新文件再删旧文件，仓库里不留两份。
    @discardableResult
    static func update(
        _ existing: JournalTemplate,
        name rawName: String,
        order rawOrder: String,
        body: String,
        in vaultURL: URL
    ) throws -> JournalTemplate {
        let name = try validatedName(rawName)
        let order = try validatedOrder(rawOrder)
        try ensureUnique(name: name, in: vaultURL, excluding: existing)
        let fileName = fileName(for: name)
        let newURL = vaultURL
            .appendingPathComponent(VaultFormat.templatesDir, isDirectory: true)
            .appendingPathComponent(fileName)
        try VaultFormat.writeAtomic(Data(encode(name: name, order: order, body: body).utf8), to: newURL)
        let oldURL = vaultURL.appendingPathComponent(existing.path)
        if oldURL.path != newURL.path, FileManager.default.fileExists(atPath: oldURL.path) {
            try FileManager.default.removeItem(at: oldURL)
        }
        return JournalTemplate(
            name: name,
            order: order,
            path: "\(VaultFormat.templatesDir)/\(fileName)",
            body: normalizeBody(body)
        )
    }

    /// 删除模板。文件已经不在时按成功处理（幂等，重试不报错）。
    static func delete(_ template: JournalTemplate, in vaultURL: URL) throws {
        let url = vaultURL.appendingPathComponent(template.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
