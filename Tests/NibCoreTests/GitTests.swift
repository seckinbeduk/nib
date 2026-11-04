import Foundation
import Testing
@testable import NibCore

/// Runs the real `git` in throwaway directories. No model calls.
@Suite("Git repository check")
struct GitTests {
    /// A new empty directory under the system temp folder, which is never inside a repo.
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nib-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func outsideARepoStagedDiffSaysSoInOneLine() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = Git(directory: directory)

        #expect(!git.isRepository())
        #expect(throws: NibError.notARepository) { try git.stagedDiff() }
        #expect(NibError.notARepository.errorDescription == "Not a git repository. Run nib inside a repo.")
    }

    @Test func inAFreshRepoStagedDiffIsEmpty() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = Git(directory: directory)
        try git.run(["init", "-q"])

        #expect(git.isRepository())
        #expect(try git.stagedDiff() == "")
    }

    /// Inside `.git` there's no work tree; before 0.4.1 this said "Nothing is staged".
    @Test func insideTheGitDirectoryIsNotARepo() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Git(directory: directory).run(["init", "-q"])
        let git = Git(directory: directory.appendingPathComponent(".git"))

        #expect(!git.isRepository())
        #expect(throws: NibError.notARepository) { try git.stagedDiff() }
    }

    /// `run` blocks its caller until git is done. In parallel tests the callers are the
    /// cooperative threads; once they are all blocked, the stderr drain must still run.
    /// The blockers give up after 10 s on their own, so a regression fails this test
    /// instead of hanging the whole run (`.timeLimit` can't fire then: it needs a free thread too).
    @Test(.timeLimit(.minutes(1)))
    func runFinishesWhileEveryCooperativeThreadIsBlocked() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = Git(directory: directory)
        let blockers = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let elapsed = await withTaskGroup(of: Duration?.self) { group in
            for _ in 0..<blockers {
                group.addTask {
                    started.signal()
                    hold(release, until: .now() + 10)
                    return nil
                }
            }
            group.addTask {
                let deadline = DispatchTime.now() + 10   // one deadline for all, not 10 s each
                for _ in 0..<blockers { hold(started, until: deadline) }
                let clock = ContinuousClock()
                let start = clock.now
                _ = try? git.run(["rev-parse", "--is-inside-work-tree"])
                let elapsed = clock.now - start
                for _ in 0..<blockers { release.signal() }
                return elapsed
            }
            var elapsed = Duration.zero
            for await value in group { if let value { elapsed = value } }
            return elapsed
        }
        #expect(elapsed < .seconds(5), "git took \(elapsed) while every cooperative thread was blocked")
    }

    @Test func notARepositoryMessagesMapToTheShortError() {
        for message in [
            "fatal: not a git repository (or any of the parent directories): .git",
            "fatal: not a git repository (or any parent up to mount point /Volumes)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).",
        ] {
            #expect(Git.repositoryError(NibError.git(message)) as? NibError == .notARepository)
        }
    }

    /// A bad GIT_DIR names the path, which says more than "run nib inside a repo".
    @Test func badGitDirPassesThrough() {
        let message = "fatal: not a git repository: '/nonexistent'"
        #expect(Git.repositoryError(NibError.git(message)) as? NibError == .git(message))
    }

    /// git's own fix ("safe.directory") must reach the user, not a misleading "not a repository".
    @Test func otherGitErrorsPassThrough() {
        let message = """
            fatal: detected dubious ownership in repository at '/Volumes/Shared/project'
            To add an exception for this directory, call:

            \tgit config --global --add safe.directory /Volumes/Shared/project
            """
        let error = Git.repositoryError(NibError.git(message))
        #expect(error as? NibError == .git(message))
    }
}

/// Blocks the calling thread on purpose, until `deadline` at the latest.
private func hold(_ semaphore: DispatchSemaphore, until deadline: DispatchTime) {
    _ = semaphore.wait(timeout: deadline)
}
