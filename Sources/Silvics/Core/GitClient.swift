import Foundation

/// 系统 git 的薄封装。
///
/// 只用命令行 git，不内嵌 libgit2：Mac 上系统自带，行为可预期，出错时输出能直接给人看。
/// GUI App 启动的进程拿不到终端里的 `ssh-agent`，所以显式指定私钥。
struct GitClient {

    var workDir: URL
    var sshKeyPath: String?
    var authorName: String
    var authorEmail: String

    enum Failure: LocalizedError {
        case gitMissing
        case failed(command: String, output: String)

        var errorDescription: String? {
            switch self {
            case .gitMissing:
                return "找不到 /usr/bin/git。需要先装 Xcode 或 Command Line Tools"
            case .failed(let command, let output):
                return "git \(command) 失败：\(output)"
            }
        }
    }

    // MARK: - 执行

    /// 执行并返回退出码与输出。判断成败只能看退出码：
    /// `allowFailure` 模式下 git 会把 `fatal: ...` 写进输出，拿输出内容当结果会误判。
    func runChecked(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = workDir

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_AUTHOR_NAME"] = authorName
        env["GIT_AUTHOR_EMAIL"] = authorEmail
        env["GIT_COMMITTER_NAME"] = authorName
        env["GIT_COMMITTER_EMAIL"] = authorEmail
        if let key = sshKeyPath, FileManager.default.fileExists(atPath: key) {
            env["GIT_SSH_COMMAND"] =
                "ssh -i \"\(key)\" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "找不到 /usr/bin/git。需要先装 Xcode 或 Command Line Tools")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    @discardableResult
    func run(_ args: [String], allowFailure: Bool = false) throws -> String {
        let result = runChecked(args)
        if result.status != 0 && !allowFailure {
            throw Failure.failed(command: args.joined(separator: " "), output: result.output)
        }
        return result.output
    }

    /// 成功才返回输出，失败一律 nil。所有「有没有 / 是什么」的判断都走这里。
    private func succeed(_ args: [String]) -> String? {
        let result = runChecked(args)
        return result.status == 0 ? result.output : nil
    }

    // MARK: - 仓库

    func isRepository() -> Bool {
        succeed(["rev-parse", "--is-inside-work-tree"]) == "true"
    }

    func initialize(remote: String, branch: String) throws {
        try run(["init", "-q", "-b", branch])
        if remoteURL() == nil {
            try run(["remote", "add", "origin", remote])
        } else {
            try run(["remote", "set-url", "origin", remote])
        }
    }

    func remoteURL() -> String? {
        let raw = succeed(["remote", "get-url", "origin"]) ?? ""
        return raw.isEmpty ? nil : raw
    }

    func setRemote(_ url: String) throws {
        if remoteURL() == nil {
            try run(["remote", "add", "origin", url])
        } else {
            try run(["remote", "set-url", "origin", url])
        }
    }

    func currentBranch() throws -> String {
        let name = succeed(["rev-parse", "--abbrev-ref", "HEAD"]) ?? ""
        return name.isEmpty || name == "HEAD" ? "main" : name
    }

    /// 工作区里有改动吗（含未跟踪文件）。`excluding` 传 vault 内相对目录，用于跳过不参与同步的类型。
    func hasLocalChanges(excluding: [String] = []) -> Bool {
        var args = ["status", "--porcelain"]
        if !excluding.isEmpty {
            args.append("--")
            args.append(".")
            args.append(contentsOf: excluding.map { ":(exclude)\($0)" })
        }
        let out = succeed(args) ?? ""
        return !out.isEmpty
    }

    func stageAll(excluding: [String] = []) throws {
        var args = ["add", "-A"]
        if !excluding.isEmpty {
            args.append("--")
            args.append(".")
            args.append(contentsOf: excluding.map { ":(exclude)\($0)" })
        }
        try run(args)
    }

    /// 把某些路径撤出暂存区。关闭「同步剪藏」时清掉可能残留的暂存。
    func unstage(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        _ = succeed(["reset", "-q", "--"] + paths)
    }

    func stagedChangesExist() -> Bool {
        let out = succeed(["diff", "--cached", "--name-only"]) ?? ""
        return !out.isEmpty
    }

    func commit(_ message: String, allowEmpty: Bool = false) throws {
        var args = ["commit", "-q", "-m", message]
        if allowEmpty { args.insert("--allow-empty", at: 1) }
        try run(args)
    }

    func fetch() throws {
        try run(["fetch", "-q", "origin"])
    }

    func remoteBranchExists(_ branch: String) -> Bool {
        succeed(["rev-parse", "--verify", "-q", "origin/\(branch)"]) != nil
    }

    /// (领先, 落后)。没有远端分支时返回 (0, 0)。
    func aheadBehind(branch: String) -> (ahead: Int, behind: Int) {
        guard remoteBranchExists(branch) else { return (0, 0) }
        let out = succeed(["rev-list", "--count", "--left-right", "HEAD...origin/\(branch)"]) ?? ""
        let parts = out.split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else {
            return (0, 0)
        }
        return (ahead, behind)
    }

    func push(branch: String, setUpstream: Bool = false) throws {
        var args = ["push", "-q", "origin", branch]
        if setUpstream { args.insert("-u", at: 1) }
        try run(args)
    }

    func mergeBase(_ ref: String) -> String? {
        let value = succeed(["merge-base", "HEAD", ref]) ?? ""
        return value.isEmpty ? nil : value
    }

    func changedPaths(from: String, to: String) -> [String] {
        let out = succeed(["diff", "--name-only", from, to]) ?? ""
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func pathExists(_ path: String, ref: String) -> Bool {
        succeed(["ls-tree", "--name-only", ref, "--", path])?.isEmpty == false
    }

    /// 读某个版本里的文件内容。文件在该版本里不存在时返回 nil（表示「远端删了」）。
    func fileContent(path: String, ref: String) -> String? {
        guard pathExists(path, ref: ref) else { return nil }
        return succeed(["show", "\(ref):\(path)"])
    }

    /// 以我方为准生成合并提交，冲突留给我们自己算，绝不让 git 往正文里写 `<<<<<<<`。
    func beginMergeKeepingOurs(_ ref: String, allowUnrelated: Bool = false) {
        var args = ["merge", "-s", "ours", "--no-commit", "--no-ff"]
        if allowUnrelated { args.append("--allow-unrelated-histories") }
        args.append(ref)
        _ = runChecked(args)
    }

    /// 工作区与某个版本完全一致吗。
    func isTreeEqual(to ref: String) -> Bool {
        // `git diff --quiet` 用退出码表达结果，没有输出。
        runChecked(["diff", "--quiet", ref]).status == 0
    }

    func resetHard(_ ref: String) {
        _ = runChecked(["reset", "--hard", "-q", ref])
    }

    func abortMerge() {
        _ = runChecked(["merge", "--abort"])
    }

    func headSubject() -> String {
        succeed(["log", "-1", "--pretty=%s"]) ?? ""
    }
}
