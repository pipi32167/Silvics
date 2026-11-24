import Foundation
import XCTest
@testable import Silvics

/// 测试用临时 vault 目录。每个用例一份，用例对象销毁时删掉。
///
/// 保存链路先写 vault 文件，所以测试**必须**传临时目录。
/// 不传的话 `GRDBNoteRepository` 会退回同步设置里的目录，往 `~/Documents/Silvics Vault` 写东西。
final class TempVault {
    let url: URL

    init(_ label: String = "vault") {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("silvics-test-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // 只读目录要先改回来，否则删不掉。
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    var notesURL: URL {
        url.appendingPathComponent(VaultFormat.notesDir, isDirectory: true)
    }

    func fileURL(_ id: String) -> URL {
        notesURL.appendingPathComponent(VaultFormat.fileName(for: id))
    }

    func repo(_ db: AppDatabase) -> GRDBNoteRepository {
        GRDBNoteRepository(db: db, vaultURL: url)
    }

    func fileText(_ id: String) throws -> String {
        try String(contentsOf: fileURL(id), encoding: .utf8)
    }

    func fileExists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(id).path)
    }
}
