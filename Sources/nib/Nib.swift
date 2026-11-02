import ArgumentParser
import Foundation
import FoundationModels
import HearthKit
import NibCore

@main
struct Nib: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nib",
        abstract: "Commit messages written on your Mac by Apple Intelligence. Your code never leaves the machine.",
        version: "0.3.0",
        subcommands: [Generate.self, Commit.self, HookCommand.self, Doctor.self],
        defaultSubcommand: Generate.self
    )
}

struct MessageOptions: ParsableArguments {
    @Option(help: "auto, conventional or plain. Default: git config nib.style, then auto.")
    var style: String?

    @Option(help: "Language for the message, e.g. en, tr, de. Default: git config nib.language, then English.")
    var language: String?

    @Option(help: "Give up after this many seconds. Default: git config nib.timeout, then 120.")
    var timeout: Double?

    @Option(help: "auto (Hearth when it's running, else Apple Intelligence), apple or hearth. Default: git config nib.engine, then auto.")
    var engine: String?

    @Flag(name: .shortAndLong, help: "Show what nib is doing.")
    var verbose = false
}

// MARK: - nib generate

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a commit message for the staged changes (the default).")

    @OptionGroup var options: MessageOptions

    @Flag(help: "Show how the diff would be split up, without calling the model.")
    var plan = false

    mutating func run() async throws {
        let git = Git()
        if plan {
            try await Runner.showPlan(git: git)
            return
        }
        let result = try await Runner.generate(git: git, options: options, log: Runner.logger(options.verbose))
        print(result.message)
    }
}

// MARK: - nib commit

struct Commit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write the message, confirm it in the terminal, and commit.",
        discussion: "Shows the message and asks: Enter to commit, e to edit it in your git editor, r to write a new one, n to cancel."
    )

    @OptionGroup var options: MessageOptions

    @Flag(name: .shortAndLong, help: "Commit right away, without asking.")
    var yes = false

    @Argument(parsing: .postTerminator, help: "Extra arguments for git commit, after --.")
    var gitArguments: [String] = []

    mutating func run() async throws {
        let git = Git()
        let log = Runner.logger(options.verbose)
        var message = try await Runner.generate(git: git, options: options, log: log).message

        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                throw ValidationError("Not running in a terminal. Use `nib commit -y` to commit without asking.")
            }
            ask: while true {
                print("\n" + message.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n") + "\n")
                print("Commit? [Y]es / [e]dit / [r]egenerate / [n]o: ", terminator: "")
                let answer = (readLine() ?? "n").trimmingCharacters(in: .whitespaces).lowercased()
                switch answer {
                case "", "y", "yes":
                    break ask
                case "e", "edit":
                    try commit(message, edit: true)
                    return
                case "r", "regenerate":
                    message = try await Runner.generate(git: git, options: options, log: log).message
                default:
                    print("Nothing committed.")
                    return
                }
            }
        }
        try commit(message, edit: false)
    }

    func commit(_ message: String, edit: Bool) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nib-\(UUID().uuidString).txt")
        try message.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let arguments = ["commit"] + (edit ? ["--edit"] : []) + ["--file", file.path] + gitArguments
        let status = Runner.passthrough(arguments)
        if status != 0 { throw ExitCode(status) }
    }
}

// MARK: - nib hook

struct HookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Have the message waiting in your editor on every `git commit`.",
        subcommands: [Install.self, Uninstall.self, Run.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install the prepare-commit-msg hook in this repository.")

        @Flag(help: "Replace an existing prepare-commit-msg hook. The old one is kept as a backup.")
        var force = false

        func run() throws {
            let git = Git()
            guard git.isRepository() else { throw ValidationError("Not inside a git repository.") }
            let directory = try git.hooksDirectory()
            switch try Hook.install(in: directory, binaryPath: Runner.executablePath(), force: force) {
            case .installed:
                print("✓ Hook installed in \(directory.path)")
            case .replaced(let backup):
                print("✓ Hook installed. Your previous hook is saved at \(backup)")
            }
            print("  Run `git commit` and your message will be waiting in the editor.")
            print("  `git commit -m \"…\"` still works as usual; nib stays out of the way.")
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove nib's hook from this repository.")

        func run() throws {
            let directory = try Git().hooksDirectory()
            print(try Hook.uninstall(from: directory) ? "✓ Hook removed." : "nib's hook isn't installed here.")
        }
    }

    /// Called by the hook. Never fails: a commit must not depend on nib.
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Fill in a commit message file (used by the hook).", shouldDisplay: false)

        @Argument var messageFile: String
        @Argument var source: String?

        mutating func run() async {
            if let source, !source.isEmpty { return }
            let git = Git()
            let url = URL(fileURLWithPath: messageFile)
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
            let commentChar: Character = git.config("core.commentChar").flatMap { $0.count == 1 ? $0.first : nil } ?? "#"
            // A template or an earlier message is already there: leave it alone.
            guard Hook.merge(message: "", into: existing, commentChar: commentChar) != nil else { return }

            printError("nib: writing your commit message on-device…")
            do {
                let options = try MessageOptions.parse([])
                let verbose = git.config("nib.verbose") == "true"
                let result = try await Runner.generate(git: git, options: options, log: Runner.logger(verbose))
                if let merged = Hook.merge(message: result.message, into: existing, commentChar: commentChar) {
                    try merged.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                printError("nib: skipped — \(Runner.describe(error))")
            }
        }
    }
}

// MARK: - nib doctor

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that everything nib needs is in place.")

    mutating func run() async throws {
        let git = Git()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        row("nib", Nib.configuration.version)
        row("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        if let reason = AppleIntelligence.unavailableReason() {
            row("Apple Intelligence", "✗ \(reason)")
        } else {
            row("Apple Intelligence", "✓ ready (\(SystemLanguageModel.default.contextSize) token context)")
        }
        let hearth = await HearthModel.status()
        if let hearth {
            row("Hearth", "✓ running \(hearth.version ?? "")" + (hearth.localModel.map { ", local model \($0)" } ?? ", no local model loaded"))
        } else {
            row("Hearth", "– not running (optional: github.com/seckinbeduk/hearth)")
        }
        let engine = (try? Runner.engine(git: Git(), options: try MessageOptions.parse([]))) ?? .auto
        let uses: String
        switch engine {
        case .apple: uses = "Apple Intelligence"
        case .hearth, .auto:
            if hearth != nil {
                uses = Runner.hearthBackend(git: Git()) == .local ? "Hearth, local model" : "Apple Intelligence through Hearth"
            } else {
                uses = engine == .hearth ? "nothing: Hearth isn't running" : "Apple Intelligence"
            }
        }
        row("engine", "\(engine.rawValue) → \(uses)")

        guard git.isRepository() else {
            row("git repository", "– not in one (run nib inside a repo)")
            return
        }
        row("git repository", "✓")

        let hookURL = try git.hooksDirectory().appendingPathComponent(Hook.name)
        let hook = try? String(contentsOf: hookURL, encoding: .utf8)
        row("hook", hook.map { Hook.isManaged($0) ? "✓ installed" : "– another prepare-commit-msg hook is installed" }
            ?? "– not installed (nib hook install)")

        let settings = try Runner.settings(git: git, options: try MessageOptions.parse([]))
        let style = settings.style == .auto ? "auto → \(settings.resolvedStyle.rawValue)" : settings.style.rawValue
        row("style", style)
        row("language", settings.language ?? "English")
        row("ticket from branch", settings.ticket ?? "none")
    }

    func row(_ label: String, _ value: String) {
        print(label.padding(toLength: 20, withPad: " ", startingAt: 0) + value)
    }
}

// MARK: - Shared

enum Runner {
    static func settings(git: Git, options: MessageOptions) throws -> Settings {
        let styleValue = options.style ?? git.config("nib.style") ?? "auto"
        guard let style = CommitStyle(rawValue: styleValue.lowercased()) else {
            throw ValidationError("Unknown style \"\(styleValue)\". Use auto, conventional or plain.")
        }
        let ticketsOn = git.config("nib.ticket")?.lowercased() != "false"
        return Settings(
            style: style,
            language: Prompts.languageName(options.language ?? git.config("nib.language")),
            ticket: ticketsOn ? Hints.ticket(fromBranch: git.currentBranch()) : nil,
            recentSubjects: style == .auto ? git.recentSubjects() : []
        )
    }

    static func generate(git: Git, options: MessageOptions,
                         log: @escaping @Sendable (String) -> Void) async throws -> Generator.Result {
        let diff = try git.stagedDiff()
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NibError.nothingStaged }
        let model = try await commitModel(git: git, options: options, log: log)

        let settings = try settings(git: git, options: options)
        let seconds = options.timeout ?? git.config("nib.timeout").flatMap { Double($0) } ?? 120
        let generator = Generator(model: model, log: log, progress: { printError("nib: " + $0) })
        let started = Date()
        let result = try await withTimeout(seconds: seconds) {
            try await generator.generate(diff: diff, settings: settings)
        }
        log("done in \(String(format: "%.1f", Date().timeIntervalSince(started)))s with \(result.modelCalls) model call(s)")
        return result
    }

    static func engine(git: Git, options: MessageOptions) throws -> Engine {
        let value = options.engine ?? git.config("nib.engine") ?? "auto"
        guard let engine = Engine(rawValue: value.lowercased()) else {
            throw ValidationError("Unknown engine \"\(value)\". Use auto, apple or hearth.")
        }
        return engine
    }

    /// Which of Hearth's models to ask: Apple Intelligence (default) or its local model.
    static func hearthBackend(git: Git) -> HearthModel.Backend {
        git.config("nib.hearthModel")?.lowercased() == "hearth" ? .local : .appleIntelligence
    }

    /// Hearth when it's running (so usage shows up there), Apple Intelligence directly otherwise.
    static func commitModel(git: Git, options: MessageOptions,
                            log: @Sendable (String) -> Void) async throws -> any CommitModel {
        let engine = try engine(git: git, options: options)
        if engine != .apple, let status = await HearthModel.status() {
            let backend = hearthBackend(git: git)
            let serving = backend == .local ? (status.localModel ?? "no local model loaded, so Apple Intelligence") : "Apple Intelligence"
            log("engine: Hearth \(status.version ?? "") (\(serving))")
            return CommitModels.hearth(backend)
        }
        if engine == .hearth { throw HearthError.notRunning }
        if let problem = AppleIntelligence.unavailableReason() {
            throw NibError.modelUnavailable(problem + "\nNo Apple Intelligence? Run Hearth (github.com/seckinbeduk/hearth) with a local model; nib uses it automatically.")
        }
        log("engine: Apple Intelligence")
        return CommitModels.appleIntelligence()
    }

    static func showPlan(git: Git) async throws {
        let files = DiffParser.parse(try git.stagedDiff())
        guard !files.isEmpty else { throw NibError.nothingStaged }
        let generator = Generator(model: CommitModels.appleIntelligence())
        let plan = Planner.plan(files, budgetChars: await generator.budgetChars(for: files))

        print("\(files.count) file(s) · \(plan.mode.rawValue) · \(plan.chunks.count) chunk(s) · budget \(plan.budgetChars) chars per prompt\n")
        print(plan.overview)
        for (index, chunk) in plan.chunks.enumerated() {
            let names = chunk.split(separator: "\n").filter { $0.hasPrefix("### ") }.map { String($0.dropFirst(4)) }
            print("\nchunk \(index + 1): \(chunk.count) chars")
            names.forEach { print("  \($0)") }
        }
        if !plan.noise.isEmpty {
            print("\nnot sent to the model:")
            plan.noise.forEach { print("  \($0.path) (\($0.kind.rawValue))") }
        }
        if !plan.omitted.isEmpty {
            print("\nleft out (too big; listed by name only):")
            plan.omitted.forEach { print("  \($0)") }
        }
    }

    static func logger(_ verbose: Bool) -> @Sendable (String) -> Void {
        if verbose {
            return { message in printError("nib: " + message) }
        }
        return { _ in }
    }

    /// Runs git attached to this terminal, so the editor works.
    static func passthrough(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            printError("nib: couldn't run git: \(error.localizedDescription)")
            return 1
        }
    }

    static func executablePath() -> String {
        Bundle.main.executableURL?.path ?? "nib"
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
