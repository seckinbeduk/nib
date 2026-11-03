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
