import Foundation

/// A thin wrapper around the `git` command.
public struct Git: Sendable {
    public var directory: URL?

    public init(directory: URL? = nil) {
        self.directory = directory
    }

    /// Runs git and returns stdout. Throws with git's own error message on failure.
    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        if let directory { process.currentDirectoryURL = directory }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw NibError.git("Couldn't run git: \(error.localizedDescription)")
        }

        // Drain stderr on another thread so a chatty git can't fill the pipe and stall.
        let errorBuffer = DataBox()
        let errorHandle = stderr.fileHandleForReading
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorBuffer.data = errorHandle.readDataToEndOfFile()
            drained.signal()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drained.wait()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorBuffer.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NibError.git(message.isEmpty ? "git \(arguments.first ?? "") failed" : message)
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// The staged changes, in a format the parser can rely on whatever the user's diff settings are.
    public func stagedDiff() throws -> String {
        // Outside a repo, `git diff --cached` falls back to `--no-index` and prints its whole usage.
        try requireRepository()
        return try run([
            "-c", "core.quotepath=false",
            "diff", "--cached", "--no-color", "--no-ext-diff", "--find-renames",
            "--src-prefix=a/", "--dst-prefix=b/", "--unified=3",
        ])
    }

    public func currentBranch() -> String? {
        let branch = (try? run(["symbolic-ref", "--short", "-q", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch?.isEmpty == false ? branch : nil
    }

    public func recentSubjects(limit: Int = 15) -> [String] {
        guard let log = try? run(["log", "-n", "\(limit)", "--no-merges", "--format=%s"]) else { return [] }
        return log.split(separator: "\n").map(String.init)
    }

    public func config(_ key: String) -> String? {
        let value = (try? run(["config", "--get", key]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// The hooks directory, honoring `core.hooksPath` and worktrees.
    public func hooksDirectory() throws -> URL {
        let path = try run(["rev-parse", "--git-path", "hooks"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }

    public func isRepository() -> Bool {
        (try? requireRepository()) != nil
    }

    /// Throws `.notARepository` outside a work tree (including inside `.git` and bare repos).
    /// Other git errors, like "dubious ownership", come through as git wrote them.
    public func requireRepository() throws {
        let output: String
        do {
            output = try run(["rev-parse", "--is-inside-work-tree"])
        } catch {
            throw Self.repositoryError(error)
        }
        guard output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { throw NibError.notARepository }
    }

    /// Maps a failed `git rev-parse` to the error nib shows. Only git's plain "no repo found here"
    /// message becomes the short one; "not a git repository: '<path>'" (a bad GIT_DIR) names the
    /// cause, so it comes through unchanged.
    static func repositoryError(_ error: Error) -> Error {
        if case NibError.git(let message) = error, message.contains("not a git repository (or any") {
            return NibError.notARepository
        }
        return error
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}
