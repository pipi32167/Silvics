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

    /// 日记提及开关变化后重扫全部日记。
    ///
    /// `MentionIndex.reindex` 先清本篇再按 `descriptor.scanMentions` 决定要不要扫，
    /// 所以关掉开关时这个调用也会把旧提及清掉。
    func reindexJournalMentions() throws {
        try db.writer.write { conn in
            let scanner = try MentionIndex.scanner(in: conn)
            let journals = try Note.filter(Column("type") == NoteTypes.journalID).fetchAll(conn)
            for journal in journals {
                try MentionIndex.reindex(
                    note: journal,
                    scanner: scanner,
                    in: conn,
                    journalScanMentions: journalScanMentions
                )
            }
        }
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

    /// 本机时区的今天，`YYYY-MM-DD`。`⌘⇧J` 与新建日记都从这里取日期。
    static func today(_ now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 日期 → UTC 零点。格式不合法返回 nil。
    static func date(from value: String) -> Date? {
        guard let normalized = try? normalized(value) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var components = DateComponents()
        let parts = normalized.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }

    /// 星期几，`周一` 这种形式。对齐原型 `weekday()`。
    static func weekday(_ value: String) -> String {
        guard let day = date(from: value) else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let index = calendar.component(.weekday, from: day) - 1
        guard names.indices.contains(index) else { return "" }
        return "周" + names[index]
    }

    /// 日期加减天数。演示数据与「昨天」类判断用；跨月跨年交给 Calendar。
    static func offset(_ value: String, by days: Int) -> String {
        guard let day = date(from: value) else { return value }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let shifted = calendar.date(byAdding: .day, value: days, to: day) else { return value }
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return value }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
