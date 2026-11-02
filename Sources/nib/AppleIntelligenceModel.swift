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

/// The same shape, with the subject held to an imperative English verb by constrained decoding.
/// A 3B model often drifts into noun phrases ("unified diff parser"); this makes that impossible.
@Generable
struct GeneratedEnglishCommit {
    @Guide(description: "Up to four short points on the important changes and why. Empty for a small change.", .maximumCount(4))
    var bullets: [String]

    @Guide(description: "Imperative summary of the whole change, at most 60 characters, no period", .pattern(/([Aa]dd|[Ff]ix|[Rr]emove|[Uu]pdate|[Rr]ename|[Mm]ove|[Ii]mprove|[Ss]implify|[Ss]upport|[Hh]andle|[Aa]llow|[Mm]ake|[Uu]se|[Rr]eplace|[Ii]ntroduce|[Ii]mplement|[Ee]xtract|[Ss]plit|[Mm]erge|[Bb]ump|[Uu]pgrade|[Dd]rop|[Cc]lean|[Dd]ocument|[Tt]est|[Ss]peed|[Pp]revent|[Aa]void|[Ee]nsure|[Ss]how|[Hh]ide|[Ee]nable|[Dd]isable|[Cc]reate|[Bb]uild|[Ii]nitialize|[Ss]et|[Cc]hange|[Rr]educe|[Ii]ncrease|[Oo]ptimize|[Rr]estore|[Rr]evert|[Rr]elease|[Pp]repare|[Mm]igrate|[Ee]xpose|[Pp]olish|[Tt]weak|[Cc]orrect|[Aa]djust|[Cc]onvert|[Cc]ache|[Vv]alidate|[Ll]og|[Ss]kip|[Kk]eep|[Ww]rite|[Ll]oad|[Ss]ave|[Pp]arse|[Rr]ender|[Ff]ormat|[Gg]enerate|[Rr]efactor|[Rr]ework|[Rr]eorganize|[Uu]nify|[Ll]imit|[Rr]aise|[Ll]ower|[Rr]eturn|[Ss]top|[Ss]tart|[Rr]un|[Gg]uard|[Ww]rap|[Ee]xport|[Ii]mport|[Ii]nclude|[Ee]xclude|[Dd]eprecate|[Dd]elete|[Ee]xtend|[Hh]arden|[Ss]horten|[Ss]ort|[Ff]ilter|[Tt]rack|[Rr]etry|[Rr]eport|[Dd]escribe|[Ee]xplain|[Rr]ewrite|[Rr]egister|[Cc]onfigure|[Ii]nstall|[Ii]ntegrate|[Dd]etect) [^\n]+/))
    var subject: String

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
                return CommitDraft(type: commit.type, scope: commit.scope, subject: commit.subject, bullets: commit.bullets)
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
