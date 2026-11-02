import Foundation
import Testing
@testable import NibCore

@Suite("Message formatting")
struct MessageFormatterTests {
    @Test func conventionalHeader() {
        let draft = CommitDraft(type: "feat", scope: "Upload", subject: "Add retry to the upload client.")
        #expect(MessageFormatter.format(draft, style: .conventional) == "feat(upload): add retry to the upload client")
    }

    @Test func stripsTypeTheModelRepeated() {
        let draft = CommitDraft(type: "fix", subject: "fix: handle empty diffs")
        #expect(MessageFormatter.format(draft, style: .conventional) == "fix: handle empty diffs")
    }

    @Test func keepsAcronyms() {
        let draft = CommitDraft(type: "feat", subject: "API keys can be rotated")
        #expect(MessageFormatter.format(draft, style: .conventional) == "feat: API keys can be rotated")
    }

    @Test func unknownTypeBecomesChore() {
        let draft = CommitDraft(type: "update", subject: "bump version")
        #expect(MessageFormatter.format(draft, style: .conventional) == "chore: bump version")
    }

    @Test func dropsJunkScopes() {
        #expect(MessageFormatter.cleanScope("none") == "")
        #expect(MessageFormatter.cleanScope("Sources") == "")
        #expect(MessageFormatter.cleanScope("src") == "")
        #expect(MessageFormatter.cleanScope("(api)") == "api")
        #expect(MessageFormatter.cleanScope("a scope that is far too long to be useful") == "")
    }

    @Test func plainStyle() {
        let draft = CommitDraft(type: "feat", scope: "ui", subject: "add dark mode")
        #expect(MessageFormatter.format(draft, style: .plain) == "Add dark mode")
    }

    @Test func headerStaysUnder72() {
        let draft = CommitDraft(type: "refactor", scope: "planner",
                                subject: "split the planner into smaller pieces so that every chunk fits in the context window")
        let header = MessageFormatter.format(draft, style: .conventional)
        #expect(header.count <= 72)
        #expect(!header.hasSuffix(" "))
    }

    @Test func bodyBulletsAreCleanedDedupedAndWrapped() {
        let draft = CommitDraft(type: "feat", subject: "add hook", bullets: [
            "* Install a prepare-commit-msg hook that never blocks a commit, even when Apple Intelligence is off or slow.",
            "- install a prepare-commit-msg hook that never blocks a commit, even when Apple Intelligence is off or slow",
            "",
            "Add hook",
        ])
        let message = MessageFormatter.format(draft, style: .conventional)
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "feat: add hook")
        #expect(lines[1] == "")
        #expect(lines[2].hasPrefix("- Install a prepare-commit-msg hook"))
        #expect(lines.allSatisfy { $0.count <= 72 })
        #expect(lines.filter { $0.hasPrefix("- ") }.count == 1)
    }

    @Test func clipDoesNotEndOnAPreposition() {
        let clipped = MessageFormatter.clip("add full-featured commit message generation with style detection", to: 56)
        #expect(clipped == "add full-featured commit message generation")
        #expect(MessageFormatter.clip("short enough", to: 56) == "short enough")
    }

    @Test func ticketFooter() {
        let draft = CommitDraft(type: "fix", subject: "handle timeouts")
        #expect(MessageFormatter.format(draft, style: .conventional, ticket: "PAY-42") == "fix: handle timeouts\n\nRefs: PAY-42")
    }
}

@Suite("Hints")
struct HintsTests {
    @Test func typeFromPaths() {
        #expect(Hints.suggestedType(for: Fixture.files(Fixture.modified("README.md"), Fixture.modified("docs/setup.md"))) == "docs")
        #expect(Hints.suggestedType(for: Fixture.files(Fixture.modified("Tests/NibTests/PlannerTests.swift"))) == "test")
        #expect(Hints.suggestedType(for: Fixture.files(Fixture.modified(".github/workflows/ci.yml"))) == "ci")
        #expect(Hints.suggestedType(for: Fixture.files(Fixture.modified("Package.swift"), Fixture.modified("Package.resolved"))) == "build")
        #expect(Hints.suggestedType(for: Fixture.files(Fixture.modified("Sources/App.swift"), Fixture.modified("README.md"))) == nil)
        #expect(Hints.suggestedType(for: Fixture.files(Fixture.added("Sources/App.swift", lines: ["x"]), Fixture.added("README.md", lines: ["y"]))) == "feat")
    }

    @Test func scopeFromCommonDirectory() {
        #expect(Hints.suggestedScope(for: Fixture.files(Fixture.modified("packages/api/src/a.ts"), Fixture.modified("packages/api/src/b.ts"))) == "api")
        #expect(Hints.suggestedScope(for: Fixture.files(Fixture.modified("Sources/NibCore/Planner.swift"))) == "nibcore")
        #expect(Hints.suggestedScope(for: Fixture.files(Fixture.modified("api/a.ts"), Fixture.modified("web/b.ts"))) == nil)
        #expect(Hints.suggestedScope(for: Fixture.files(Fixture.modified("main.swift"))) == nil)
    }

    @Test func ticketFromBranch() {
        #expect(Hints.ticket(fromBranch: "feature/PAY-1234-retry") == "PAY-1234")
        #expect(Hints.ticket(fromBranch: "main") == nil)
        #expect(Hints.ticket(fromBranch: nil) == nil)
    }

    @Test func styleFollowsHistory() {
        #expect(Hints.detectStyle(recentSubjects: ["feat: a", "fix(ui): b", "chore: c", "Update readme"]) == .conventional)
        #expect(Hints.detectStyle(recentSubjects: ["Add login", "Fix crash on launch", "Update readme"]) == .plain)
        #expect(Hints.detectStyle(recentSubjects: ["Initial commit"]) == .conventional)
    }

    @Test func languageNames() {
        #expect(Prompts.languageName("tr") == "Turkish")
        #expect(Prompts.languageName("Turkish") == "Turkish")
        #expect(Prompts.languageName(nil) == nil)
        #expect(Prompts.languageLine("English") == "Write in English.")
    }
}

@Suite("Hook")
struct HookTests {
    let gitTemplate = """

    # Please enter the commit message for your changes. Lines starting
    # with '#' will be ignored, and an empty message aborts the commit.
    #
    # On branch main
    """

    @Test func messageGoesOnTop() throws {
        let merged = try #require(Hook.merge(message: "feat: add hook", into: gitTemplate))
        #expect(merged.hasPrefix("feat: add hook\n# ✎ Written on-device"))
        #expect(merged.contains("# Please enter the commit message"))
    }

    @Test func existingMessageIsLeftAlone() {
        #expect(Hook.merge(message: "feat: x", into: "Ticket: \n" + gitTemplate) == nil)
    }

    @Test func customCommentChar() throws {
        let merged = try #require(Hook.merge(message: "fix: y", into: "\n; comment", commentChar: ";"))
        #expect(merged == "fix: y\n\n; comment")
    }

    @Test func scriptNeverBlocks() {
        let script = Hook.script(binaryPath: "/usr/local/bin/nib")
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(Hook.isManaged(script))
        #expect(script.contains("[ -n \"$2\" ] && exit 0"))
        #expect(script.contains("|| true"))
        #expect(script.hasSuffix("exit 0\n"))
    }

    @Test func installBacksUpForeignHookOnlyWithForce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nib-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hook = directory.appendingPathComponent(Hook.name)
        try "#!/bin/sh\necho mine\n".write(to: hook, atomically: true, encoding: .utf8)

        #expect(throws: NibError.self) { try Hook.install(in: directory, binaryPath: "nib", force: false) }

        let result = try Hook.install(in: directory, binaryPath: "nib", force: true)
        guard case .replaced = result else { Issue.record("expected a backup"); return }
        #expect(Hook.isManaged(try String(contentsOf: hook, encoding: .utf8)))

        #expect(try Hook.uninstall(from: directory))
        #expect(try String(contentsOf: hook, encoding: .utf8).contains("echo mine"))
    }
}
