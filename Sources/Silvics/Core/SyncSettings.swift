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
    /// 自动同步：改完笔记后空闲一段时间推一次。
    var autoSync: Bool = false

    var lastSyncedAt: Int64 = 0
    var lastMessage: String = ""

    static let defaultsKey = "silvics.sync.settings"

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
