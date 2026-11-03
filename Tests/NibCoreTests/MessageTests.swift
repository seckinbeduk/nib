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

    @Test func scopeThatRepeatsTheTypeIsDropped() {
        let draft = CommitDraft(type: "docs", scope: "docs", subject: "show demo in README")
        #expect(MessageFormatter.format(draft, style: .conventional) == "docs: show demo in README")
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

    // Build files with docs-like names are build, unless they live under docs/.
    @Test func buildFilesThatLookLikeDocsAreBuild() {
        func type(_ paths: String...) -> String? {
            Hints.suggestedType(for: DiffParser.parse(paths.map { Fixture.modified($0) }.joined(separator: "\n")))
        }
        #expect(type("requirements.txt") == "build")
        #expect(type("requirements-dev.txt") == "build")
        #expect(type("CMakeLists.txt") == "build")
        #expect(type("README.md", "requirements.txt") == nil)
        #expect(type("docs/requirements.txt") == "docs")
        #expect(type("docs/Makefile", "docs/index.rst") == "docs")
        #expect(type("docs/notes.txt") == "docs")
        #expect(type("LICENSE") == "docs")
        #expect(!Hints.isDocs("requirements.txt"))
        #expect(!Hints.isDocs("requirements-dev.txt"))
    }

    @Test func pathsOverruleTheModelOnlyWhenCertain() {
        #expect(Hints.reconcile(modelType: "feat", suggested: "docs") == "docs")
        #expect(Hints.reconcile(modelType: "chore", suggested: "test") == "test")
        #expect(Hints.reconcile(modelType: "refactor", suggested: "feat") == "feat")
        #expect(Hints.reconcile(modelType: "chore", suggested: "feat") == "chore")
        #expect(Hints.reconcile(modelType: "fix", suggested: nil) == "fix")
        #expect(Hints.reconcile(modelType: "chore", suggested: "build") == "chore")
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

@Suite("Engine")
struct EngineTests {
    @Test func names() {
        #expect(Engine(rawValue: "auto") == .auto)
        #expect(Engine(rawValue: "hearth") == .hearth)
        #expect(Engine(rawValue: "apple") == .apple)
        #expect(Engine(rawValue: "cloud") == nil)
    }
}

@Suite("Subject repair")
struct SubjectRepairTests {
    @Test func verbListSubjectIsReplacedByTheFirstBullet() {
        let draft = CommitDraft(type: "feat", scope: "", subject: "add track, detect, reflect, modify",
                                bullets: ["Add version and localModel tracking to HearthConnection", "Implement probe function"])
        let message = MessageFormatter.format(draft, style: .conventional)
        #expect(message.hasPrefix("feat: add version and localModel tracking to HearthConnection"))
        #expect(!message.contains("- Add version and localModel tracking"))   // not repeated in the body
        #expect(message.contains("- Implement probe function"))
    }

    @Test func normalSubjectsAreLeftAlone() {
        #expect(!MessageFormatter.looksLikeList("add retry to the upload client"))
        #expect(!MessageFormatter.looksLikeList("fix crash, hang and leak in the parser on launch"))
        #expect(!MessageFormatter.looksLikeList("add tests for login, signup and logout"))
        #expect(!MessageFormatter.looksLikeList("support macOS, iOS, or visionOS"))
        #expect(MessageFormatter.looksLikeList("add track, detect, reflect, modify"))
        #expect(MessageFormatter.looksLikeList("update parser, planner, hints"))
    }

    // nib 187ba0c: a list of noun phrases, not one change.
    @Test func nounListSubjectIsReplacedByTheFirstBullet() {
        let draft = CommitDraft(type: "feat", subject: "add model clarity, error guidance, config clarity, platform update",
                                bullets: ["Add `auto` case to `Engine` enum to clarify model origin",
                                          "Fix `HearthError` `.notRunning` to include start instructions"])
        #expect(MessageFormatter.looksLikeList(draft.subject))
        let message = MessageFormatter.format(draft, style: .conventional)
        #expect(message.hasPrefix("feat: add `auto` case to `Engine` enum to clarify model origin\n"))
        #expect(message.contains("- Fix `HearthError` `.notRunning` to include start instructions"))
    }

    // nib a9d9187: a generic verb and the file's name, nothing about what changed.
    @Test func fileNameSubjectIsReplacedByTheFirstBullet() {
        let paths = [".github/workflows/ci.yml"]
        let draft = CommitDraft(type: "ci", scope: "workflows", subject: "update ci workflow",
                                bullets: ["Update CI runner to xcode-27", "Upgrade checkout action to v5"])
        #expect(MessageFormatter.looksVague(draft.subject, paths: paths, scope: draft.scope, type: draft.type))
        let message = MessageFormatter.format(draft, style: .conventional, paths: paths)
        #expect(message.hasPrefix("ci(workflows): update CI runner to xcode-27\n"))
        #expect(message.contains("- Upgrade checkout action to v5"))
    }

    @Test func vagueMatchingFoldsPluralsAndExtensions() {
        #expect(MessageFormatter.looksVague("update workflows", paths: [".github/workflows/ci.yml"]))
        #expect(MessageFormatter.looksVague("update ci.yml", paths: [".github/workflows/ci.yml"]))
        #expect(MessageFormatter.looksVague("update the README", paths: ["README.md"]))
        #expect(MessageFormatter.looksVague("change parser config", paths: ["Sources/Parsers/Parser.swift"]))
    }

    @Test func specificSubjectsAreNotVague() {
        let paths = ["Sources/Upload/RetryPolicy.swift"]
        #expect(!MessageFormatter.looksVague("update the retry limit to 5", paths: paths))
        #expect(!MessageFormatter.looksVague("add retry to the upload client", paths: paths))   // not a generic verb
        #expect(!MessageFormatter.looksVague("update ci workflow", paths: []))                  // nothing to compare with
        #expect(!MessageFormatter.looksVague("update CI runner to xcode-27", paths: [".github/workflows/ci.yml"], type: "ci"))
    }

    @Test func weakSubjectStaysWhenThereIsNoBetterBullet() {
        let paths = [".github/workflows/ci.yml"]
        let noBullets = CommitDraft(type: "ci", subject: "update ci workflow")
        #expect(MessageFormatter.format(noBullets, style: .conventional, paths: paths) == "ci: update ci workflow")
        let vagueBullet = CommitDraft(type: "ci", subject: "update ci workflow", bullets: ["Update workflows"])
        #expect(MessageFormatter.format(vagueBullet, style: .conventional, paths: paths).hasPrefix("ci: update ci workflow\n"))
    }
}

/// Scope checks against the changed files, with the file lists of real nib commits.
@Suite("Scope reconciliation")
struct ScopeReconciliationTests {
    /// What Generator does: suggest from the files, then check the model's scope.
    private func scope(_ model: String, _ diffs: String...) -> String {
        let files = DiffParser.parse(diffs.joined(separator: "\n"))
        let signal = files.filter { NoiseFilter.classify($0) == nil }
        let used = signal.isEmpty ? files : signal
        return Hints.reconcileScope(modelScope: model, suggested: Hints.suggestedScope(for: used), files: used)
    }

    @Test func testTargetsFoldIntoTheirModule() {
        let files = Fixture.files(Fixture.modified("Sources/NibCore/CommitMessage.swift"),
                                  Fixture.modified("Tests/NibCoreTests/MessageTests.swift"))
        #expect(Hints.suggestedScope(for: files) == "nibcore")
    }

    @Test func docsBesideCodeDontHideTheSharedDirectory() {
        let files = Fixture.files(Fixture.modified("Sources/NibCore/Hearth.swift"), Fixture.modified("README.md"))
        #expect(Hints.suggestedScope(for: files) == "nibcore")
        #expect(Hints.suggestedScope(for: Fixture.files(Fixture.modified("README.md"))) == nil)
    }

    // nib 7fa1409: "package" came from Package.swift. The root manifest doesn't count for the shared
    // directory, so Sources/nib and Tests/NibTests give the real scope.
    @Test func scopeFromTheManifestNameBecomesTheModule() {
        let diffs = [Fixture.modified("Package.swift", section: "let package = Package("),
                     Fixture.modified("Sources/nib/AppleIntelligenceModel.swift"),
                     Fixture.added("Tests/NibTests/ErrorTranslationTests.swift", lines: ["import Testing"])]
        let files = DiffParser.parse(diffs.joined(separator: "\n"))
        let reconciled = Hints.reconcileScope(modelScope: "package", suggested: Hints.suggestedScope(for: files), files: files)
        #expect(reconciled == "nib")
        let draft = CommitDraft(type: "feat", scope: reconciled, subject: "add error mapping")
        #expect(MessageFormatter.format(draft, style: .conventional) == "feat(nib): add error mapping")
    }

    // A manifest name is still dropped when there is no module to offer instead.
    @Test func scopeFromTheManifestNameIsDroppedWithoutAModule() {
        #expect(scope("package", Fixture.modified("Package.swift"), Fixture.modified("Sources/NibCore/Planner.swift"),
                      Fixture.modified("Sources/nib/Nib.swift")) == "")
        #expect(scope("deps", Fixture.modified("Package.swift"), Fixture.modified("Package.resolved")) == "deps")
    }

    // A new dependency used in code: the module isn't clearly better than "deps", so the model's scope stays.
    @Test func scopeStaysWhenARootManifestChangedToo() {
        #expect(scope("deps", Fixture.modified("Package.swift"), Fixture.modified("Package.resolved"),
                      Fixture.modified("Sources/nib/Nib.swift")) == "deps")
        #expect(scope("deps", Fixture.modified("requirements-dev.txt"), Fixture.modified("server/app.py")) == "deps")
    }

    // Every pip file names the same thing, so "requirements" is a manifest name for requirements-dev.txt too.
    @Test func pipFileNamesAreManifestNames() {
        #expect(scope("requirements", Fixture.modified("requirements-dev.txt"), Fixture.modified("server/app.py")) == "server")
        #expect(scope("requirements", Fixture.modified("requirements.txt"), Fixture.modified("server/app.py")) == "server")
        #expect(scope("requirements", Fixture.modified("requirements-dev.txt")) == "")
    }

    // Nested manifests count for the shared directory, and their name is dropped like a root one.
    @Test func manifestNameIsReplacedByThePackage() {
        #expect(scope("package", Fixture.modified("packages/web/package.json"), Fixture.modified("packages/web/src/index.ts")) == "web")
        #expect(scope("package", Fixture.modified("package.json"), Fixture.modified("packages/web/src/index.ts")) == "web")
    }

    // A source file's name is a real scope even when other files changed too (Swift files are named after their type).
    @Test func scopeFromOneSourceFileIsKept() {
        #expect(scope("planner", Fixture.modified("Sources/NibCore/Planner.swift", section: "enum Planner {"),
                      Fixture.modified("Tests/NibCoreTests/PlannerTests.swift"),
                      Fixture.modified("Sources/NibCore/Generator.swift")) == "planner")
    }

    // requirements.txt ends in .txt but is a build file, not docs: it still decides the shared directory.
    @Test func buildFilesThatLookLikeDocsCount() {
        let files = Fixture.files(Fixture.modified("services/billing/requirements.txt"),
                                  Fixture.modified("services/auth/handlers.py"))
        #expect(Hints.suggestedScope(for: files) == "services")
    }

    // nib f4b9fd5: "file-paths" is no directory, file or declaration; the module is.
    @Test func inventedScopeBecomesTheModule() {
        #expect(scope("file-paths",
                      Fixture.modified("Sources/NibCore/CommitMessage.swift", added: ["    public static func format(paths: [String] = [])"]),
                      Fixture.modified("Sources/NibCore/Generator.swift"),
                      Fixture.modified("Tests/NibCoreTests/MessageTests.swift")) == "nibcore")
    }

    @Test func scopesThatMatchTheFilesAreKept() {
        #expect(scope("nib", Fixture.modified("Sources/nib/Nib.swift")) == "nib")                       // fb6f947
        #expect(scope("workflows", Fixture.modified(".github/workflows/ci.yml")) == "workflows")        // a9d9187
        #expect(scope("planner", Fixture.modified("Sources/NibCore/Planner.swift"),
                      Fixture.modified("Tests/NibCoreTests/PlannerTests.swift")) == "planner")
        #expect(scope("nibcore", Fixture.modified("Sources/NibCore/Hearth.swift"), Fixture.modified("README.md")) == "nibcore")
    }

    // With no shared directory there is nothing better, so the model's scope stays.
    @Test func scopeStaysWithoutABetterOne() {
        #expect(scope("model", Fixture.modified("README.md"), Fixture.modified("Sources/NibCore/CommitMessage.swift"),     // ee935c5
                      Fixture.added("Sources/NibCore/Hearth.swift", lines: ["import Foundation"]),
                      Fixture.modified("Sources/nib/Nib.swift"), Fixture.modified("Tests/NibCoreTests/MessageTests.swift")) == "model")
        #expect(scope("nibcore", Fixture.modified("README.md"), Fixture.modified("Sources/NibCore/Generator.swift"),       // 0d5f750
                      Fixture.modified("Sources/nib/Nib.swift"), Fixture.modified("Tests/NibCoreTests/GeneratorTests.swift")) == "nibcore")
        #expect(scope("deps", Fixture.modified("Package.resolved")) == "deps")                                             // lockfile only
        #expect(scope("", Fixture.modified("Sources/NibCore/Planner.swift")) == "")
    }

    @Test func declaredNameIsKept() {
        let hearth = Fixture.modified("Sources/NibCore/Hearth.swift", section: "public enum Engine: String, Sendable, CaseIterable, Codable {",
                                      removed: ["    case apple"], added: ["    case apple", "    case auto"])
        #expect(Fixture.files(hearth).first?.hunks.first?.contains("enum Engine") == true)   // the parser keeps the @@ line
        #expect(scope("engine", hearth) == "engine")
    }

    // Plural and snake_case declarations still count; each file has a suggestion that would otherwise win.
    @Test func declaredNamesMatchPluralAndSnakeCase() {
        #expect(scope("policies", Fixture.modified("Sources/NibCore/Rules.swift", section: "enum Policies {")) == "policies")
        #expect(scope("file-path", Fixture.modified("app/billing/models.py", added: ["    def file_path(self):"])) == "file-path")
    }

    // Known weakness: a concept declared with `let` isn't recognized, so the module wins.
    @Test func knownWeaknessLetDeclarationsAreNotNames() {
        #expect(scope("engine", Fixture.modified("Sources/NibCore/Hearth.swift", added: ["    static let engine = Engine.auto"])) == "nibcore")
    }

    // Known weakness: any declaration counts, so a weak scope survives when it's a declared name.
    @Test func knownWeaknessAnyDeclarationCounts() {
        #expect(scope("string", Fixture.modified("Sources/NibCore/Text.swift", section: "extension String {")) == "string")
    }
}
