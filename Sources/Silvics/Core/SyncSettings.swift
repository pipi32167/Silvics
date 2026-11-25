import Foundation

/// 备份与同步的设置。存 UserDefaults，不进数据库。
struct SyncSettings: Codable, Equatable {
    /// vault 目录。空串表示用默认位置 `~/Documents/Silvics Vault`。
    var vaultPath: String = ""
    var remoteURL: String = ""
    var branch: String = "main"
    var authorName: String = "Silvics"
    var authorEmail: String = "silvics@localhost"
    /// 为空则用默认的 `~/.ssh/id_ed25519`。
    var sshKeyPath: String = ""
    /// 后台定时同步：按间隔做一次「拉 + 合 + 推」。默认开，间隔 15 分钟。
    var backgroundSync: Bool = true
    /// 定时同步间隔（分钟）。只允许 5 / 10 / 15 / 30 / 60。
    var syncIntervalMinutes: Int = 15
    /// 是否把剪藏一起同步。关掉时导出跳过 clips/，导入也不拉剪藏。
    var syncClips: Bool = true

    var lastSyncedAt: Int64 = 0
    var lastMessage: String = ""

    static let defaultsKey = "silvics.sync.settings"
    static let allowedIntervals = [5, 10, 15, 30, 60]

    static var defaultVaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/Silvics Vault", isDirectory: true)
    }

    var vaultURL: URL {
        let raw = vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return Self.defaultVaultURL }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    var effectiveSSHKeyPath: String {
        let raw = sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/id_ed25519").path
        }
        return (raw as NSString).expandingTildeInPath
    }

    var isConfigured: Bool {
        !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case vaultPath, remoteURL, branch, authorName, authorEmail, sshKeyPath
        case backgroundSync, syncIntervalMinutes, syncClips, lastSyncedAt, lastMessage
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SyncSettings()
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? fallback.vaultPath
        remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL) ?? fallback.remoteURL
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? fallback.branch
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName) ?? fallback.authorName
        authorEmail = try c.decodeIfPresent(String.self, forKey: .authorEmail) ?? fallback.authorEmail
        sshKeyPath = try c.decodeIfPresent(String.self, forKey: .sshKeyPath) ?? fallback.sshKeyPath
        backgroundSync = try c.decodeIfPresent(Bool.self, forKey: .backgroundSync) ?? fallback.backgroundSync
        syncIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes)
            ?? fallback.syncIntervalMinutes
        syncClips = try c.decodeIfPresent(Bool.self, forKey: .syncClips) ?? fallback.syncClips
        lastSyncedAt = try c.decodeIfPresent(Int64.self, forKey: .lastSyncedAt) ?? 0
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage) ?? ""
        if !Self.allowedIntervals.contains(syncIntervalMinutes) {
            syncIntervalMinutes = fallback.syncIntervalMinutes
        }
    }

    // MARK: - 校验

    /// 远端地址格式。空串表示没配（只做本地备份）。
    var remoteURLProblem: String? {
        let raw = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        if raw.hasPrefix("git@") || raw.hasPrefix("ssh://") { return nil }
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return nil }
        // 本机路径与 file://：自测与「放在移动硬盘上的裸仓」都用得上
        if raw.hasPrefix("/") || raw.hasPrefix("~/") || raw.hasPrefix("file://") { return nil }
        return "地址要以 git@ / https:// / / 开头"
    }

    var branchProblem: String? {
        let raw = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "分支名不能为空" }
        if raw.contains(" ") || raw.contains("..") { return "分支名不合法" }
        return nil
    }

    var isReadyToSync: Bool {
        isConfigured && remoteURLProblem == nil && branchProblem == nil
    }

    // MARK: - 读写

    static func load(from defaults: UserDefaults = .standard) -> SyncSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(SyncSettings.self, from: data)
        else { return SyncSettings() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
