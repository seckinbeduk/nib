import Foundation

/// The language model nib talks to. The real one is Apple Intelligence; tests use a fake.
public protocol CommitModel: Sendable {
    /// Total tokens one session can hold: instructions, prompt and response together.
    var contextTokens: Int { get }
    /// Exact token count of `text`, or nil when the model can't count.
    func tokenCount(_ text: String) async -> Int?
    /// A free-text answer.
    func respond(instructions: String, prompt: String) async throws -> String
    /// A structured commit message. With `imperativeEnglish`, the subject must start with an English verb.
    func draft(instructions: String, prompt: String, imperativeEnglish: Bool) async throws -> CommitDraft
}

public enum ModelError: Error, Equatable {
    /// The prompt didn't fit in the context window.
    case contextOverflow
    /// The model declined or a guardrail fired.
    case refused
}

public enum NibError: Error, LocalizedError, Equatable {
    case nothingStaged
    case timedOut(seconds: Double)
    case modelUnavailable(String)
    case git(String)
    case hookExists(String)

    public var errorDescription: String? {
        switch self {
        case .nothingStaged: "Nothing is staged. Stage your changes with `git add` first."
        case .timedOut(let seconds): "Gave up after \(Int(seconds)) seconds."
        case .modelUnavailable(let reason): reason
        case .git(let message): message
        case .hookExists(let path): "There's already a hook at \(path). Run `nib hook install --force` to replace it (the old one is kept as a backup)."
        }
    }
}

/// What the generator needs to know about the repo and the user's preferences.
public struct Settings: Sendable {
    public var style: CommitStyle
    /// A language name like "Turkish", or nil for English.
    public var language: String?
    public var ticket: String?
    public var recentSubjects: [String]
    public var maxChunks: Int

    public init(style: CommitStyle = .auto, language: String? = nil, ticket: String? = nil,
                recentSubjects: [String] = [], maxChunks: Int = 4) {
        self.style = style
        self.language = language
        self.ticket = ticket
        self.recentSubjects = recentSubjects
        self.maxChunks = maxChunks
    }

    public var resolvedStyle: CommitStyle {
        style == .auto ? Hints.detectStyle(recentSubjects: recentSubjects) : style
    }
}

public struct Generator: Sendable {
    public struct Result: Sendable {
        public var message: String
        public var plan: Plan
        public var modelCalls: Int
    }

    /// Tokens kept free for instructions, hints and the response.
    public static let reservedTokens = 1_100
    /// Used until the model has counted real tokens. Code is token-dense, so this is cautious.
    public static let fallbackCharsPerToken = 3.0

    let model: any CommitModel
    let log: @Sendable (String) -> Void
    let progress: @Sendable (String) -> Void

    /// - Parameters:
    ///   - log: Details, shown with --verbose.
    ///   - progress: The few lines worth showing anyway, when a run will take a while.
    public init(model: any CommitModel, log: @escaping @Sendable (String) -> Void = { _ in },
                progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.model = model
        self.log = log
        self.progress = progress
    }

    /// Characters of diff that fit in one prompt, calibrated with the model's own tokenizer.
    public func budgetChars(for files: [FileDiff]) async -> Int {
        let tokens = max(model.contextTokens - Self.reservedTokens, 600)
        var ratio = Self.fallbackCharsPerToken
        let sample = String(files.map(Planner.render).joined(separator: "\n").prefix(12_000))
        if sample.count >= 500, let counted = await model.tokenCount(sample), counted > 0 {
            ratio = min(max(Double(sample.count) / Double(counted), 1.5), 6)
            log("calibrated: \(String(format: "%.2f", ratio)) characters per token")
        }
        return Int(Double(tokens) * ratio)
    }

    public func generate(diff raw: String, settings: Settings) async throws -> Result {
        let files = DiffParser.parse(raw)
        guard !files.isEmpty else { throw NibError.nothingStaged }

        var budget = await budgetChars(for: files)
        var lastError: Error = ModelError.contextOverflow
        // If the model still overflows (the estimate was off), shrink the chunks and try again.
        for attempt in 0..<3 {
            let plan = Planner.plan(files, budgetChars: budget, maxChunks: settings.maxChunks)
            log("plan: \(plan.mode.rawValue), \(plan.chunks.count) chunk(s), budget \(plan.budgetChars) chars"
                + (plan.noise.isEmpty ? "" : ", \(plan.noise.count) noisy file(s) skipped")
                + (plan.omitted.isEmpty ? "" : ", \(plan.omitted.count) file(s) omitted"))
            do {
                return try await run(plan, files: files, settings: settings)
            } catch ModelError.contextOverflow {
                lastError = ModelError.contextOverflow
                budget = budget * 6 / 10
                if attempt < 2 { log("context window exceeded, retrying with smaller chunks") }
            }
        }
        throw lastError
    }

    func run(_ plan: Plan, files: [FileDiff], settings: Settings) async throws -> Result {
        let signal = files.filter { NoiseFilter.classify($0) == nil }
        let hints = Prompts.hintLines(type: Hints.suggestedType(for: files),
                                      scope: Hints.suggestedScope(for: signal.isEmpty ? files : signal))
        let composeInstructions = Prompts.composeInstructions(language: settings.language)
        var calls = 0

        let prompt: String
        switch plan.mode {
        case .single:
            prompt = Prompts.composePrompt(overview: plan.overview, diff: plan.chunks.first, hints: hints)
        case .mapReduce:
            var summaries: [String] = []
            let instructions = Prompts.summarizeInstructions(language: settings.language)
            progress("big change: reading it in \(plan.chunks.count) parts…")
            for (index, chunk) in plan.chunks.enumerated() {
                let started = Date()
                calls += 1
                do {
                    summaries.append(try await model.respond(instructions: instructions, prompt: chunk))
                } catch ModelError.refused {
                    // Don't lose the whole commit over one chunk: fall back to the file names.
                    summaries.append(Self.fallbackSummary(for: chunk))
                }
                log("part \(index + 1)/\(plan.chunks.count): \(chunk.count) chars in \(Self.seconds(since: started))")
            }
            summaries = try await condense(summaries, overview: plan.overview, budget: plan.budgetChars,
                                           language: settings.language, calls: &calls)
            prompt = Prompts.reducePrompt(overview: plan.overview, summaries: summaries, hints: hints)
        }

        let started = Date()
        calls += 1
        let english = settings.language.map(Prompts.isEnglish) ?? true
        let draft = try await model.draft(instructions: composeInstructions, prompt: prompt, imperativeEnglish: english)
        log("message: \(prompt.count) chars in \(Self.seconds(since: started))")
        let message = MessageFormatter.format(draft, style: settings.resolvedStyle, ticket: settings.ticket)
        return Result(message: message, plan: plan, modelCalls: calls)
    }

    /// When the summaries themselves are too long, summarize them again (at most twice).
    func condense(_ summaries: [String], overview: String, budget: Int, language: String?,
                  calls: inout Int) async throws -> [String] {
        var summaries = summaries
        for _ in 0..<2 {
            let size = summaries.reduce(overview.count) { $0 + $1.count + 1 }
            guard size > budget else { return summaries }
            log("condensing \(summaries.count) summaries")
            var groups: [[String]] = [[]]
            var groupSize = 0
            for summary in summaries {
                if groupSize + summary.count > budget, !groups[groups.count - 1].isEmpty {
                    groups.append([])
                    groupSize = 0
                }
                groups[groups.count - 1].append(summary)
                groupSize += summary.count + 1
            }
            var condensed: [String] = []
            for group in groups {
                calls += 1
                let joined = Planner.truncate(group.joined(separator: "\n"), to: budget)
                condensed.append(try await model.respond(instructions: Prompts.condenseInstructions(language: language),
                                                         prompt: joined))
            }
            summaries = condensed
        }
        // Still too long: keep what fits.
        let room = max(budget - overview.count, 200)
        return [Planner.truncate(summaries.joined(separator: "\n"), to: room)]
    }

    static func seconds(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    static func fallbackSummary(for chunk: String) -> String {
        chunk.split(separator: "\n")
            .filter { $0.hasPrefix("### ") }
            .map { "- changes in " + $0.dropFirst(4) }
            .joined(separator: "\n")
    }
}

/// Runs `operation`, giving up after `seconds`.
public func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw NibError.timedOut(seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw NibError.timedOut(seconds: seconds) }
        return result
    }
}
