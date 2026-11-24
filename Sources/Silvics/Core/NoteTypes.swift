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
    /// 是否进 `⌘P` 按标题打开。
    let inQuickOpen: Bool
    /// 是否计入孤儿统计。
    let countsAsOrphan: Bool
    /// 是否跑未链接提及扫描。
    let scanMentions: Bool
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

    static let note = NoteType(
        id: noteID,
        fileDir: "notes",
        titleEditable: true,
        validatesTitle: true,
        linkable: true,
        inQuickOpen: true,
        countsAsOrphan: true,
        scanMentions: true,
        metaNamespace: nil,
        metaFields: []
    )

    static let journal = NoteType(
        id: journalID,
        fileDir: "journal",
        titleEditable: false,
        validatesTitle: false,
        linkable: false,
        inQuickOpen: false,
        countsAsOrphan: false,
        scanMentions: false,
        metaNamespace: "journal",
        metaFields: ["date", "carryFrom"]
    )

    static let all: [String: NoteType] = [
        note.id: note,
        journal.id: journal,
    ]

    /// 未注册的类型按普通笔记处理，不报错 —— 旧版本读到新类型时不能崩。
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
