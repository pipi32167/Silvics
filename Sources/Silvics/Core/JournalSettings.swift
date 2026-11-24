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
