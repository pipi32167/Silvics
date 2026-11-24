import Foundation

/// 外观设置：正文字号、代码字号、行距、字体族。
///
/// 存 UserDefaults，不进数据库。理由与 `SyncSettings` 相同：设置属于本机，
/// 不该跟着笔记 vault 同步走。样式不进正文，`note.body` 永远是纯文本。
struct AppearanceSettings: Codable, Equatable {
    /// 字体族。只影响渲染，不影响正文。
    enum FontFamily: String, Codable, CaseIterable, Identifiable {
        case system
        case serif
        case mono

        var id: Self { self }

        var title: String {
            switch self {
            case .system: return "系统无衬线"
            case .serif: return "系统衬线"
            case .mono: return "等宽"
            }
        }
    }

    var bodySize: Double = 15
    var codeSize: Double = 13.5
    var lineSpacing: Double = 5
    var fontFamily: FontFamily = .system

    static let bodySizeRange: ClosedRange<Double> = 13...19
    static let codeSizeRange: ClosedRange<Double> = 11...16
    static let lineSpacingRange: ClosedRange<Double> = 3...9

    static let defaultsKey = "silvics.appearance.settings"

    // 标题字号按正文比例缩放。基准：正文 15 时一级标题 26。
    static let headingRatios: [Double] = [26, 21, 18, 16.5, 15.5, 15]
    static let referenceBodySize: Double = 15

    init() {}

    /// 解码后统一夹取，旧版本或手改的 JSON 不会把界面弄坏。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppearanceSettings()
        bodySize = try container.decodeIfPresent(Double.self, forKey: .bodySize) ?? fallback.bodySize
        codeSize = try container.decodeIfPresent(Double.self, forKey: .codeSize) ?? fallback.codeSize
        lineSpacing = try container.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? fallback.lineSpacing
        fontFamily = try container.decodeIfPresent(FontFamily.self, forKey: .fontFamily) ?? fallback.fontFamily
        clamp()
    }

    mutating func clamp() {
        bodySize = min(max(bodySize, Self.bodySizeRange.lowerBound), Self.bodySizeRange.upperBound)
        codeSize = min(max(codeSize, Self.codeSizeRange.lowerBound), Self.codeSizeRange.upperBound)
        lineSpacing = min(max(lineSpacing, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound)
    }

    var clamped: AppearanceSettings {
        var copy = self
        copy.clamp()
        return copy
    }

    /// 某一级标题的字号。保留一位小数，避免 15.5000001 这种值。
    func headingSize(level: Int) -> Double {
        let index = min(max(level, 1), Self.headingRatios.count) - 1
        let raw = Self.headingRatios[index] * bodySize / Self.referenceBodySize
        return (raw * 10).rounded() / 10
    }

    var isDefault: Bool { self == AppearanceSettings() }

    // MARK: - 读写

    static func load(from defaults: UserDefaults = .standard) -> AppearanceSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(AppearanceSettings.self, from: data)
        else { return AppearanceSettings() }
        return decoded.clamped
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(clamped) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
