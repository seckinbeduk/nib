import Testing
@testable import NibCore

@Suite("Changing the type")
struct ChangingTypeTests {
    @Test func swapsTheTypeAndKeepsScopeSubjectAndBody() {
        let message = "feat(hints): add file classification\n\n- Classify test files"
        #expect(MessageFormatter.changingType(of: message, to: "fix") == "fix(hints): add file classification\n\n- Classify test files")
        #expect(MessageFormatter.changingType(of: "feat: add retry", to: "refactor") == "refactor: add retry")
        #expect(MessageFormatter.changingType(of: "feat(api)!: drop v1", to: "fix") == "fix(api)!: drop v1")
    }

    @Test func scopeThatBecomesTheTypeIsDropped() {
        #expect(MessageFormatter.changingType(of: "feat(docs): add install guide", to: "docs") == "docs: add install guide")
        #expect(MessageFormatter.changingType(of: "chore(ci)!: pin runner image", to: "ci") == "ci!: pin runner image")
    }

    @Test func plainMessagesHaveNoTypeToChange() {
        #expect(MessageFormatter.changingType(of: "Add retry to the upload client", to: "fix") == nil)
        #expect(MessageFormatter.changingType(of: "Note: something", to: "fix") == nil)
    }

    @Test func longerTypeKeepsTheHeaderUnder72() {
        let header = "ci: " + String(repeating: "x", count: 68)
        let changed = MessageFormatter.changingType(of: header, to: "refactor")!
        #expect(changed.hasPrefix("refactor: "))
        #expect(changed.count <= MessageFormatter.headerLimit)
    }

    @Test func everyTypeHasOneKey() {
        let keys = MessageFormatter.typeKeys
        #expect(Set(keys.map(\.key)).count == keys.count)
        #expect(keys.allSatisfy { $0.key.count == 1 && MessageFormatter.allowedTypes.contains($0.type) })
        #expect(Set(keys.map(\.type)) == Set(MessageFormatter.allowedTypes).subtracting(["revert"]))
    }
}
