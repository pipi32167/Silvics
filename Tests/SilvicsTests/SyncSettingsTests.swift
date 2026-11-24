import XCTest
@testable import Silvics

final class SyncSettingsTests: XCTestCase {

    func testOldJSONWithoutNewFieldsStillLoads() throws {
        // 0.1.2 及以前的 JSON：没有 backgroundSync / syncIntervalMinutes
        let old = #"""
        {"vaultPath":"/tmp/v","remoteURL":"git@github.com:me/vault.git","branch":"main",
         "authorName":"Silvics","authorEmail":"silvics@localhost","sshKeyPath":"","lastSyncedAt":0,"lastMessage":""}
        """#
        let decoded = try JSONDecoder().decode(SyncSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.remoteURL, "git@github.com:me/vault.git")
        XCTAssertTrue(decoded.backgroundSync, "老数据默认开定时同步")
        XCTAssertEqual(decoded.syncIntervalMinutes, 15)
    }

    func testInvalidIntervalFallsBack() throws {
        let json = #"{"syncIntervalMinutes":7}"#
        let decoded = try JSONDecoder().decode(SyncSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.syncIntervalMinutes, 15, "只允许 5/10/15/30/60")
    }

    func testRemoteURLValidation() {
        var settings = SyncSettings()
        XCTAssertNil(settings.remoteURLProblem, "空串表示不配远端")

        for ok in ["git@github.com:me/v.git", "https://github.com/me/v.git",
                   "ssh://git@host/me/v.git", "/tmp/bare.git", "file:///tmp/bare.git"] {
            settings.remoteURL = ok
            XCTAssertNil(settings.remoteURLProblem, ok)
        }
        for bad in ["github.com/me/v", "ftp://x/y.git", "随便写的"] {
            settings.remoteURL = bad
            XCTAssertNotNil(settings.remoteURLProblem, bad)
        }
    }

    func testBranchValidation() {
        var settings = SyncSettings()
        XCTAssertNil(settings.branchProblem)
        settings.branch = "  "
        XCTAssertNotNil(settings.branchProblem)
        settings.branch = "feat/a..b"
        XCTAssertNotNil(settings.branchProblem)
    }

    func testReadyToSync() {
        var settings = SyncSettings()
        XCTAssertFalse(settings.isReadyToSync)
        settings.remoteURL = "git@github.com:me/v.git"
        XCTAssertTrue(settings.isReadyToSync)
        settings.branch = ""
        XCTAssertFalse(settings.isReadyToSync)
    }
}

final class SyncSchedulerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func shouldRun(
        nowOffset: TimeInterval,
        lastAttemptOffset: TimeInterval? = nil,
        failures: Int = 0,
        enabled: Bool = true,
        interval: Int = 15,
        syncing: Bool = false,
        conflicts: Bool = false
    ) -> Bool {
        SyncScheduler.shouldRun(
            now: start.addingTimeInterval(nowOffset),
            startedAt: start,
            lastAttempt: lastAttemptOffset.map { start.addingTimeInterval($0) },
            consecutiveFailures: failures,
            enabled: enabled,
            intervalMinutes: interval,
            isSyncing: syncing,
            hasConflicts: conflicts
        )
    }

    func testStartupDelay() {
        XCTAssertFalse(shouldRun(nowOffset: 5), "启动 10 秒内不跑")
        XCTAssertTrue(shouldRun(nowOffset: 11))
    }

    func testInterval() {
        XCTAssertFalse(shouldRun(nowOffset: 20, lastAttemptOffset: 10, interval: 15))
        XCTAssertTrue(shouldRun(nowOffset: 10 + 15 * 60))
    }

    func testBackoffAfterFailures() {
        XCTAssertEqual(SyncScheduler.backoff(failures: 0), 0)
        XCTAssertEqual(SyncScheduler.backoff(failures: 1), 5 * 60)
        XCTAssertEqual(SyncScheduler.backoff(failures: 2), 15 * 60)
        XCTAssertEqual(SyncScheduler.backoff(failures: 9), 60 * 60, "最多退到 60 分钟")

        // 失败一次后按 5 分钟退避：100 秒不跑，310 秒跑
        XCTAssertFalse(shouldRun(nowOffset: 110, lastAttemptOffset: 10, failures: 1))
        XCTAssertTrue(shouldRun(nowOffset: 10 + 5 * 60, lastAttemptOffset: 10, failures: 1))
        // 失败三次后按 60 分钟退避
        XCTAssertFalse(shouldRun(nowOffset: 10 + 30 * 60, lastAttemptOffset: 10, failures: 3))
    }

    func testNeverWhenDisabledOrBusyOrConflicted() {
        XCTAssertFalse(shouldRun(nowOffset: 3600, enabled: false))
        XCTAssertFalse(shouldRun(nowOffset: 3600, syncing: true))
        XCTAssertFalse(shouldRun(nowOffset: 3600, conflicts: true))
    }
}

final class RemoteProbeTests: XCTestCase {

    func testExplainCommonFailures() {
        XCTAssertTrue(RemoteProbe.explain("git@github.com: Permission denied (publickey).").contains("没有权限"))
        XCTAssertTrue(RemoteProbe.explain("ERROR: Repository not found.").contains("仓库不存在"))
        XCTAssertTrue(RemoteProbe.explain("ssh: Could not resolve hostname github.com").contains("域名解析"))
        XCTAssertTrue(RemoteProbe.explain("ssh: connect to host x port 22: Operation timed out").contains("超时"))
        XCTAssertTrue(RemoteProbe.explain("Host key verification failed.").contains("主机指纹"))
        XCTAssertEqual(RemoteProbe.explain("something odd"), "连接失败")
    }

    func testFirstLineTruncates() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(RemoteProbe.firstLine(long).count, 201)
    }

    func testEmptyURLRejected() async {
        let outcome = await RemoteProbe.check(remoteURL: "  ", sshKeyPath: nil, timeout: 1)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.message, "先填远端地址")
    }
}
