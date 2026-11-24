import Foundation

/// 远端仓库连通性探测。用 `git ls-remote`，不依赖工作区。
struct RemoteProbe {

    struct Outcome: Equatable {
        var ok: Bool
        var message: String
        var detail: String
    }

    /// 探测（会真的连一次远端，10 秒超时）。
    static func check(
        remoteURL: String,
        sshKeyPath: String?,
        timeout: TimeInterval = 10
    ) async -> Outcome {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return Outcome(ok: false, message: "先填远端地址", detail: "") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["ls-remote", "--heads", url]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        if let key = sshKeyPath, !key.isEmpty, FileManager.default.fileExists(atPath: key) {
            env["GIT_SSH_COMMAND"] =
                "ssh -i \"\(key)\" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let finished = DispatchSemaphore(value: 0)
        do {
            try process.run()
        } catch {
            return Outcome(ok: false, message: "找不到 /usr/bin/git", detail: "")
        }

        var output = ""
        let reader = Thread {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            finished.signal()
        }
        reader.start()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if finished.wait(timeout: .now()) == .success { break }
            usleep(50_000)
        }

        if process.isRunning {
            process.terminate()
            return Outcome(ok: false, message: "连接超时（\(Int(timeout)) 秒）", detail: "")
        }

        let status = process.terminationStatus
        if status == 0 {
            let heads = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            return Outcome(
                ok: true,
                message: heads.isEmpty ? "连接成功，仓库是空的" : "连接成功，\(heads.count) 个分支",
                detail: heads.prefix(4).map { line in
                    line.split(separator: "\t").last.map(String.init) ?? line
                }.joined(separator: " · ")
            )
        }
        return Outcome(ok: false, message: explain(output), detail: firstLine(output))
    }

    /// 把 git / ssh 的输出翻成一句话。顺序有讲究：先认最常见的三种。
    static func explain(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("permission denied") || text.contains("publickey") {
            return "没有权限：检查私钥，或把公钥加到远端账号"
        }
        if text.contains("repository not found") || text.contains("not found") {
            return "仓库不存在，或这个账号没有访问权限"
        }
        if text.contains("could not resolve host") || text.contains("name or service not known") {
            return "域名解析失败，检查网络或代理"
        }
        if text.contains("connection timed out") || text.contains("operation timed out") {
            return "连接超时，检查网络"
        }
        if text.contains("host key verification failed") {
            return "主机指纹校验失败，先手动 ssh 连接一次确认"
        }
        if text.contains("no such file") || text.contains("does not appear to be a git repository") {
            return "地址不对：不像一个 git 仓库"
        }
        return "连接失败"
    }

    static func firstLine(_ output: String) -> String {
        let line = output.components(separatedBy: "\n").first ?? ""
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}
