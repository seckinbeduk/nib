import Foundation
import Testing
@testable import NibCore

@Suite("Generator")
struct GeneratorTests {
    @Test func smallDiffTakesOneCall() async throws {
        let model = FakeModel()
        model.draftResult = CommitDraft(type: "feat", scope: "upload", subject: "Add retry", bullets: ["Retries three times"])
        let result = try await Generator(model: model).generate(diff: Fixture.modified("Sources/Upload.swift"),
                                                                settings: Settings(style: .conventional))
        #expect(result.modelCalls == 1)
        #expect(model.respondPrompts.isEmpty)
        #expect(model.draftPrompts.count == 1)
        #expect(model.draftPrompts[0].contains("### Sources/Upload.swift"))
        #expect(result.message == "feat(upload): add retry\n\n- Retries three times")
    }

    @Test func bigDiffIsSummarizedThenComposed() async throws {
        let model = FakeModel()
        model.contextTokens = 2_000   // budget = (2000 - 1100) * 3 = 2700 chars
        let diff = Fixture.big("Engine.swift", hunks: 10, linesPerHunk: 20)
        let result = try await Generator(model: model).generate(diff: diff, settings: Settings(style: .conventional))
        #expect(result.plan.mode == .mapReduce)
        #expect(model.respondPrompts.count == result.plan.chunks.count)
        #expect(model.draftPrompts.count == 1)
        #expect(model.draftPrompts[0].contains("- summary of part 1"))
        #expect(!model.draftPrompts[0].contains("let value"))   // raw diff isn't in the final prompt
    }

    @Test func calibratesWithRealTokenCounts() async {
        let model = FakeModel()
        model.charsPerToken = 4.5
        let files = DiffParser.parse(Fixture.big("A.swift", hunks: 10, linesPerHunk: 20))
        let budget = await Generator(model: model).budgetChars(for: files)
        let expected = Int(Double(4_096 - Generator.reservedTokens) * 4.5)
        #expect(abs(budget - expected) < expected / 50)   // token counts are whole numbers
    }

    @Test func smallDiffSkipsTheTokenCount() async {
        let model = FakeModel()
        model.charsPerToken = 4.5
        let files = DiffParser.parse(Fixture.modified("A.swift"))
        let budget = await Generator(model: model).budgetChars(for: files)
        #expect(budget == Int(Double(4_096 - Generator.reservedTokens) * Generator.fallbackCharsPerToken))
    }

    @Test func retriesWithSmallerChunksAfterOverflow() async throws {
        let model = FakeModel()
        model.draftErrors = [ModelError.contextOverflow]
        let result = try await Generator(model: model).generate(diff: Fixture.modified("A.swift"), settings: Settings())
        #expect(model.draftPrompts.count == 2)
        #expect(result.message.hasPrefix("feat: add the thing"))
    }

    @Test func refusedChunkFallsBackToFileNames() async throws {
        let model = FakeModel()
        model.contextTokens = 2_000
        model.respondErrors = [ModelError.refused]
        let diff = Fixture.big("Engine.swift", hunks: 10, linesPerHunk: 20)
        _ = try await Generator(model: model).generate(diff: diff, settings: Settings())
        #expect(model.draftPrompts[0].contains("- changes in Engine.swift"))
    }

    @Test func emptyDiffThrows() async {
        await #expect(throws: NibError.nothingStaged) {
            try await Generator(model: FakeModel()).generate(diff: "", settings: Settings())
        }
    }

    @Test func verbConstraintOnlyForEnglish() async throws {
        let model = FakeModel()
        _ = try await Generator(model: model).generate(diff: Fixture.modified("A.swift"), settings: Settings())
        _ = try await Generator(model: model).generate(diff: Fixture.modified("A.swift"), settings: Settings(language: "Turkish"))
        #expect(model.imperativeFlags == [true, false])
    }

    @Test func hintsReachThePrompt() async throws {
        let model = FakeModel()
        _ = try await Generator(model: model).generate(diff: Fixture.modified("docs/guide.md"), settings: Settings())
        #expect(model.draftPrompts[0].contains("type is \"docs\""))
        #expect(model.draftPrompts[0].contains("Facts:\n- 1 file changed: 1 modified"))
    }

    @Test func ticketAndStyleAreApplied() async throws {
        let model = FakeModel()
        let settings = Settings(style: .auto, ticket: "PAY-7", recentSubjects: ["Add login", "Fix crash", "Tweak copy"])
        let result = try await Generator(model: model).generate(diff: Fixture.modified("A.swift"), settings: settings)
        #expect(result.message == "Add the thing\n\nRefs: PAY-7")
    }

    @Test func timeoutFires() async {
        await #expect(throws: NibError.timedOut(seconds: 0.1)) {
            try await withTimeout(seconds: 0.1) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
    }
}
