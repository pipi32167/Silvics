import Foundation

/// 一种笔记类型的描述符。
///
/// 加类型 = 加一个描述符 + 一条迁移（如果需要新列），不改判断逻辑。
/// 界面上所有「日记要不要进 ⌘P / 算不算孤儿 / 跑不跑提及」都从这里读，不要写 `if type == "journal"`。
struct NoteType: Equatable, Sendable {
    let id: String
    /// vault 里的目录名。空串表示放 `notes/`。
    let fileDir: String
    /// 用户能否改标题。日记日期即身份，不能改。
    let titleEditable: Bool
    /// 是否套 `TextNormalizer.validateTitle`。
    let validatesTitle: Bool
    /// 能否被 `[[ ]]` 指向。
    let linkable: Bool
    /// 正文是否解析 `[[ ]]` 产生出边。剪藏是单向的，不产出边。
    let emitsLinks: Bool
    /// 标题是否进提及自动机。剪藏不是提及目标，避免每条笔记都被建议链到它。
    let isMentionTarget: Bool
    /// 是否进「全部」列表与计数。
    let inMainList: Bool
    /// 是否进 `⌘P` 按标题打开。
    let inQuickOpen: Bool
    /// 是否计入孤儿统计。
    let countsAsOrphan: Bool
    /// 是否跑未链接提及扫描。
    let scanMentions: Bool
    /// 标签是否来自正文。为 false 时读 `note.tags`（剪藏标签由 AI 生成，不写进正文）。
    let tagsInBody: Bool
    /// frontmatter 里的类型段名，例如 `journal:`。`nil` 表示没有类型段。
    let metaNamespace: String?
    /// 类型段里被识别的键。其余键按「未知」原样保留。
    let metaFields: [String]

    /// 文件名是否由日期派生（跨设备必须确定）。
    var idIsDateDerived: Bool { id == NoteTypes.journalID }
}

enum NoteTypes {

    static let noteID = "note"
    static let journalID = "journal"
    static let clipID = "clip"

    static let note = NoteType(
        id: noteID,
        fileDir: "notes",
        titleEditable: true,
        validatesTitle: true,
        linkable: true,
        emitsLinks: true,
        isMentionTarget: true,
        inMainList: true,
        inQuickOpen: true,
        countsAsOrphan: true,
        scanMentions: true,
        tagsInBody: true,
        metaNamespace: nil,
        metaFields: []
    )

    static let journal = NoteType(
        id: journalID,
        fileDir: "journal",
        titleEditable: false,
        validatesTitle: false,
        linkable: false,
        emitsLinks: true,
        isMentionTarget: false,
        inMainList: false,
        inQuickOpen: false,
        countsAsOrphan: false,
        scanMentions: false,
        tagsInBody: true,
        metaNamespace: "journal",
        metaFields: ["date", "carryFrom"]
    )

    /// 剪藏：单向引用。别的类型能指向它，它自己不产出边、不跑提及、不进主列表。
    ///
    /// 标题不走概念笔记的断言校验：原文标题是一篇文章的名字，不是一句断言。
    /// 清洗规则在 `ClipTitle`（见 `docs/需求-剪藏.md` §7）。
    static let clip = NoteType(
        id: clipID,
        fileDir: "clips",
        titleEditable: true,
        validatesTitle: false,
        linkable: true,
        emitsLinks: false,
        isMentionTarget: false,
        inMainList: false,
        inQuickOpen: false,
        countsAsOrphan: false,
        scanMentions: false,
        tagsInBody: false,
        metaNamespace: "clip",
        metaFields: ClipFields.allKeys
    )

    static let all: [String: NoteType] = [
        note.id: note,
        journal.id: journal,
        clip.id: clip,
    ]

    /// 未注册的类型按普通笔记处理，不报错 —— 旧版本读到新类型时不能崩。
    ///
    /// 日记的提及开关是运行时设置，不在这里读：`GRDBNoteRepository.journalScanMentions`
    /// 带着它进入保存链路，避免静态描述符随全局状态变化。
    static func descriptor(for id: String) -> NoteType {
        all[id] ?? note
    }

    static func isKnown(_ id: String) -> Bool {
        all[id] != nil
    }

    /// 日记的确定性 id：`j` + 无分隔符日期。两台设备同一天必须算出同一个 id。
    static func journalID(for date: String) -> String {
        "j" + date.filter { $0.isNumber }
    }
}
