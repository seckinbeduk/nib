import Testing
@testable import nib

/// `git nib <name>` passes these on unchanged; everything else becomes `nib commit …`.
/// Renaming a subcommand must show up here.
@Suite("git nib pass-through names")
struct InvocationNamesTests {
    @Test func passThroughIsTheSubcommandsAndHelp() {
        #expect(Nib.passThrough == ["generate", "commit", "hook", "doctor", "help"])
    }
}
