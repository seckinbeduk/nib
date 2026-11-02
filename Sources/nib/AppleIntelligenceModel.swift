import Foundation
import FoundationModels
import NibCore

/// The shape of a commit message, filled in by guided generation.
/// Properties are generated in order, so the model writes the details first and the
/// one-line subject after: it summarizes what it has already said instead of guessing.
@Generable
struct GeneratedCommit {
    @Guide(description: "Up to four short points on the important changes and why. Empty for a small change.", .maximumCount(4))
    var bullets: [String]

    @Guide(description: "Imperative summary of the whole change, at most 60 characters, no period")
    var subject: String

    @Guide(description: "The kind of change", .anyOf(["feat", "fix", "refactor", "perf", "docs", "test", "build", "ci", "chore", "style"]))
    var type: String

    @Guide(description: "A short lowercase name for the area changed, or an empty string")
    var scope: String
}

/// The same shape, with the subject split into a verb chosen from a list and the rest.
/// A 3B model often drifts into noun phrases ("unified diff parser"); a fixed choice of verb
/// makes that impossible, and lists are something guided generation always supports.
@Generable
struct GeneratedEnglishCommit {
    @Guide(description: "Up to four short points on the important changes and why, in the imperative. Empty for a small change.", .maximumCount(4))
    var bullets: [String]

    @Guide(description: "The verb the summary starts with", .anyOf(Prompts.imperativeVerbs))
    var verb: String

    @Guide(description: "The rest of the one-line summary after the verb, lowercase, no period. Example: \"retry to the upload client\"")
    var rest: String

    @Guide(description: "The kind of change", .anyOf(["feat", "fix", "refactor", "perf", "docs", "test", "build", "ci", "chore", "style"]))
    var type: String

    @Guide(description: "A short lowercase name for the area changed, or an empty string")
    var scope: String
}

/// Apple's on-device model, through the Foundation Models framework.
struct AppleIntelligenceModel: CommitModel {
    /// Diffs are input to transform, not content to judge, so use the permissive guardrails.
    let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    var contextTokens: Int {
        AppleIntelligence.unavailableReason() == nil ? model.contextSize : 4_096
    }

    func tokenCount(_ text: String) async -> Int? {
        if #available(macOS 26.4, *) {
            return try? await model.tokenCount(for: Instructions(text))
        }
        return nil
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 250)
            return try await session.respond(to: prompt, options: options).content
        } catch {
            throw Self.translate(error)
        }
    }

    func draft(instructions: String, prompt: String, imperativeEnglish: Bool) async throws -> CommitDraft {
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 400)
        if imperativeEnglish {
            do {
                let session = LanguageModelSession(model: model, instructions: instructions)
                let commit = try await session.respond(to: prompt, generating: GeneratedEnglishCommit.self, options: options).content
                return CommitDraft(type: commit.type, scope: commit.scope, subject: commit.verb + " " + commit.rest,
                                   bullets: commit.bullets)
            } catch {
                // Overflow is handled upstream; anything else, try again without the pattern.
                if Self.translate(error) as? ModelError == .contextOverflow { throw ModelError.contextOverflow }
            }
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let commit = try await session.respond(to: prompt, generating: GeneratedCommit.self, options: options).content
            return CommitDraft(type: commit.type, scope: commit.scope, subject: commit.subject, bullets: commit.bullets)
        } catch {
            throw Self.translate(error)
        }
    }

    /// Maps framework errors onto the two nib knows how to recover from.
    static func translate(_ error: Error) -> Error {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize: return ModelError.contextOverflow
            case .guardrailViolation: return ModelError.refused
            default: break
            }
        }
        let description = String(describing: error)
        if description.contains("exceededContextWindowSize") { return ModelError.contextOverflow }
        if description.contains("guardrailViolation") || description.contains("refusal") { return ModelError.refused }
        return error
    }
}

enum AppleIntelligence {
    /// Why the model can't be used, or nil when it's ready.
    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac can't run Apple Intelligence (it needs Apple silicon)."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is off. Turn it on in System Settings → Apple Intelligence & Siri."
            case .modelNotReady:
                return "The Apple Intelligence model isn't ready yet; it may still be downloading. Try again in a few minutes."
            @unknown default:
                return "Apple Intelligence isn't available right now."
            }
        @unknown default:
            return "Apple Intelligence isn't available right now."
        }
    }
}
