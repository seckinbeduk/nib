import Foundation
import FoundationModels
import NibCore
import Testing
@testable import nib

/// `translate` only inspects error values, so these build the errors by hand and never
/// reach Apple Intelligence or Hearth. They run anywhere the macOS 27 SDK builds, CI included.
@Suite("Error translation")
struct ErrorTranslationTests {
    private func translate(_ error: Error) -> Error {
        FoundationCommitModel<SystemLanguageModel>.translate(error)
    }

    @Test func contextSizeExceededBecomesContextOverflow() {
        let error = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 4_096, tokenCount: 5_000, debugDescription: "too long"))
        #expect(translate(error) as? ModelError == .contextOverflow)
    }

    @Test func guardrailViolationBecomesRefused() {
        let error = LanguageModelError.guardrailViolation(.init(debugDescription: "guardrail"))
        #expect(translate(error) as? ModelError == .refused)
    }

    @Test func refusalBecomesRefused() {
        let error = LanguageModelError.refusal(.init(explanation: "no", debugDescription: "refusal"))
        #expect(translate(error) as? ModelError == .refused)
    }

    @Test func otherErrorsPassThrough() {
        struct Unrelated: Error {}
        #expect(translate(Unrelated()) is Unrelated)
    }
}
