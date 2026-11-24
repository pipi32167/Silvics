import Foundation
import GRDB

/// 日记的创建与查找。本批不接界面，这里是唯一入口。
///
/// id 由日期派生（`NoteTypes.journalID`），所以两台设备同一天算出同一个 id，
/// 不会因为同步各建一篇。
extension GRDBNoteRepository {

    /// 上一个有日记的日子（`date` 之前最近的），按日记类型段的 `date` 比较。
    ///
    /// 不含当天，也不要求是「昨天」：11-21 与 11-23 都有日记时，11-24 的上一篇是 11-23。
    func previousJournal(before date: String) throws -> Note? {
        let journals: [Note] = try db.reader.read { conn in
            try Note.filter(Column("type") == NoteTypes.journalID).fetchAll(conn)
        }
        return journals
            .compactMap { note -> (day: String, note: Note)? in
                guard let day = note.metaFields["date"], !day.isEmpty, day < date else { return nil }
                return (day, note)
            }
            .sorted { $0.day > $1.day }
            .first?.note
    }

    /// 取某天的日记；不存在就按模板与承接新建并保存。
    ///
    /// 已存在时直接返回已有那篇：不覆盖正文、不重复插入承接。
    /// 新建顺序：拼模板骨架 → 找上一个有日记的日子 → 未完成项插到正文最前。
    @discardableResult
    func journalNote(on date: String, using templates: [String] = []) throws -> Note {
        let day = try JournalDate.normalized(date)
        let id = NoteTypes.journalID(for: day)
        if let existing = try note(id: id) { return existing }
        // 手写的日记可能换了 id，同日期的也算已存在。
        if let existing = try journal(on: day) { return existing }

        var body = JournalTemplates.skeleton(named: templates, in: vaultURL)
        var meta = ["date": day]

        if let previous = try previousJournal(before: day), let previousDay = previous.metaFields["date"] {
            let items = JournalCarry.openTodos(in: previous.body)
            let carried = JournalCarry.insert(into: body, from: previousDay, items: items)
            if carried != body {
                body = carried
                meta["carryFrom"] = previousDay
            }
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var note = Note(
            id: id,
            title: day,
            titleKey: TextNormalizer.key(day),
            body: body,
            status: .seedling,
            createdAt: now,
            updatedAt: now,
            bodyHash: TextNormalizer.bodyHash(body),
            type: NoteTypes.journalID,
            meta: "{}",
            extra: "{}"
        )
        note.setMetaFields(meta)
        return try save(note)
    }

    /// 按类型段里的日期找日记。找不到返回 nil。
    func journal(on date: String) throws -> Note? {
        let journals: [Note] = try db.reader.read { conn in
            try Note.filter(Column("type") == NoteTypes.journalID).fetchAll(conn)
        }
        return journals.first { $0.metaFields["date"] == date }
    }
}

/// 日记日期（`YYYY-MM-DD`）的规范化与校验。日期即身份，格式不能松。
enum JournalDate {

    enum DateError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let raw): return "日记日期要写成 YYYY-MM-DD：\(raw)"
            }
        }
    }

    /// 校验并去掉首尾空白。不是真实存在的日期（含 2 月 30 日）就抛错。
    static func normalized(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day)
        else {
            throw DateError.invalid(raw)
        }
        return trimmed
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let first = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: first)
        else { return 31 }
        return range.count
    }
}
