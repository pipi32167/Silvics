import Foundation

/// 剪藏的本机设置。存 UserDefaults，不进 vault。
///
/// 这些是「怎么剪」的偏好，不是任何一篇剪藏的内容。改完立即生效，没有保存按钮。
struct ClipSettings: Codable, Equatable {
    /// 抓取后立即调模型整理。关掉只存正文，列表标「待整理」。
    var autoSummarize: Bool = true
    var titleStrategy: ClipTitleStrategy = .smart
    /// 摘要字数上限。
    var summaryLimit: Int = 300
    /// 希望模型给出几个标签。
    var targetTagCount: Int = 4
    /// 抓取超时（秒）。
    var fetchTimeout: Int = 15
    /// 打开剪藏后自动标已读。
    var markReadOnOpen: Bool = true

    static let defaultsKey = "silvics.clips.settings"
    static let allowedSummaryLimits = [150, 300, 500]
    static let allowedTagCounts = [3, 4, 5]
    static let allowedTimeouts = [10, 15, 30]

    /// 测试可换成独立 suite，避免污染真实 UserDefaults。
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ClipSettings()
        autoSummarize = try c.decodeIfPresent(Bool.self, forKey: .autoSummarize) ?? fallback.autoSummarize
        titleStrategy = try c.decodeIfPresent(ClipTitleStrategy.self, forKey: .titleStrategy) ?? fallback.titleStrategy
        summaryLimit = try c.decodeIfPresent(Int.self, forKey: .summaryLimit) ?? fallback.summaryLimit
        targetTagCount = try c.decodeIfPresent(Int.self, forKey: .targetTagCount) ?? fallback.targetTagCount
        fetchTimeout = try c.decodeIfPresent(Int.self, forKey: .fetchTimeout) ?? fallback.fetchTimeout
        markReadOnOpen = try c.decodeIfPresent(Bool.self, forKey: .markReadOnOpen) ?? fallback.markReadOnOpen
        self = repaired()
    }

    /// 越界值钳回默认。手改过 UserDefaults 也不能把界面弄坏。
    func repaired() -> ClipSettings {
        var copy = self
        if !Self.allowedSummaryLimits.contains(copy.summaryLimit) { copy.summaryLimit = 300 }
        if !Self.allowedTagCounts.contains(copy.targetTagCount) { copy.targetTagCount = 4 }
        if !Self.allowedTimeouts.contains(copy.fetchTimeout) { copy.fetchTimeout = 15 }
        return copy
    }

    // MARK: - 读写

    static func load(from defaults: UserDefaults = ClipSettings.defaults) -> ClipSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ClipSettings.self, from: data)
        else { return ClipSettings() }
        return decoded.repaired()
    }

    func save(to defaults: UserDefaults = ClipSettings.defaults) {
        guard let data = try? JSONEncoder().encode(repaired()) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(from defaults: UserDefaults = ClipSettings.defaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    static func reset() {
        clear()
    }
}
