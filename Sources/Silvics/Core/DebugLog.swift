import Foundation

/// 开发期日志。写到 `/tmp/silvics-debug.log`，方便从终端看。
enum DebugLog {
    static func write(_ message: String) {
        #if DEBUG
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/silvics-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
    }
}
