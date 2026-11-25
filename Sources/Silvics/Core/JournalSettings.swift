import Foundation

/// 日记的全局开关。目前只有一项：日记是否参与未链接提及扫描。
///
/// 为什么存 UserDefaults 而不是 frontmatter：这是本机偏好，不是笔记内容。
/// 读出来的值由 `AppState` 灌进 `GRDBNoteRepository.journalScanMentions`，
/// 再由保存链路带给 `MentionIndex`。这里只管持久化，不参与扫描判断。
enum JournalMentionSettings {

    static let defaultsKey = "silvics.journal.scanMentions"

    /// 测试可换成独立 suite，避免污染真实 UserDefaults。
    static var defaults: UserDefaults = .standard

    /// 日记是否参与提及扫描。默认关（原型与 `docs/笔记类型与元数据.md` 的约定）。
    static var scanMentions: Bool {
        get { defaults.bool(forKey: defaultsKey) }
        set { defaults.set(newValue, forKey: defaultsKey) }
    }

    /// 恢复默认：日记不参与提及扫描。
    static func reset() {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// 新建日记上次用过的模板名。`⌘⇧J` 新建时先按这份记忆取模板，失效才退回默认前两个。
///
/// 为什么存 UserDefaults 而不是 frontmatter：这是「下次新建用什么」的本机偏好，
/// 不是任何一篇日记的内容；已有日记的正文不受影响。
enum JournalTemplateMemory {

    static let defaultsKey = "silvics.journal.templateNames"

    /// 测试可换成独立 suite，避免污染真实 UserDefaults。
    static var defaults: UserDefaults = .standard

    /// 记住的模板名。空数组表示「没有记忆」，由调用方退回默认。
    static var names: [String] {
        get { defaults.stringArray(forKey: defaultsKey) ?? [] }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if cleaned.isEmpty {
                defaults.removeObject(forKey: defaultsKey)
            } else {
                defaults.set(cleaned, forKey: defaultsKey)
            }
        }
    }

    /// 忘掉记忆，下次新建回到 order 最小的前两个。
    static func reset() {
        defaults.removeObject(forKey: defaultsKey)
    }
}
