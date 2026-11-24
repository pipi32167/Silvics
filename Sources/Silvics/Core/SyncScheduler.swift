import Foundation

/// 定时同步的判定。纯函数，方便单测。
///
/// 规则：
/// - 关掉开关、正在同步、有未处理冲突时都不跑。
/// - 正常间隔用用户设置的分钟数；失败后按 5 / 15 / 60 分钟退避。
/// - 启动后先等 10 秒，避开首次启动的索引重建。
enum SyncScheduler {

    static let startupDelay: TimeInterval = 10
    static let backoffMinutes = [5, 15, 60]

    static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let index = min(failures - 1, backoffMinutes.count - 1)
        return TimeInterval(backoffMinutes[index] * 60)
    }

    static func shouldRun(
        now: Date,
        startedAt: Date,
        lastAttempt: Date?,
        consecutiveFailures: Int,
        enabled: Bool,
        intervalMinutes: Int,
        isSyncing: Bool,
        hasConflicts: Bool
    ) -> Bool {
        guard enabled, !isSyncing, !hasConflicts else { return false }
        guard intervalMinutes > 0 else { return false }

        // 第一次：只要过了启动延迟就跑一次，不必等满一个间隔。
        guard let lastAttempt else {
            return now.timeIntervalSince(startedAt) >= startupDelay
        }
        let wait: TimeInterval = consecutiveFailures > 0
            ? backoff(failures: consecutiveFailures)
            : TimeInterval(intervalMinutes * 60)
        return now.timeIntervalSince(lastAttempt) >= wait
    }
}
