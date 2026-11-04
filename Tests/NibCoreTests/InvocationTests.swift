import Testing
@testable import NibCore

@Suite("git nib")
struct InvocationTests {
    private let passThrough: Set<String> = ["generate", "commit", "hook", "doctor", "help"]

    private func gitNib(_ arguments: String...) -> [String] {
        Invocation.arguments(executable: "/opt/homebrew/bin/git-nib", arguments: arguments, passThrough: passThrough)
    }

    @Test func nibItselfIsLeftAlone() {
        #expect(Invocation.arguments(executable: "/opt/homebrew/bin/nib", arguments: ["-y"], passThrough: passThrough) == ["-y"])
        #expect(Invocation.arguments(executable: "nib", arguments: [], passThrough: passThrough) == [])
    }

    @Test func gitNibAloneCommits() {
        #expect(gitNib() == ["commit"])
    }

    @Test func optionsGoToCommit() {
        #expect(gitNib("-y") == ["commit", "-y"])
        #expect(gitNib("-v") == ["commit", "-v"])
        #expect(gitNib("--", "--amend") == ["commit", "--", "--amend"])
        // An option's value that happens to be a subcommand name is still a value.
        #expect(gitNib("--style", "commit") == ["commit", "--style", "commit"])
        #expect(gitNib("-y", "-h") == ["commit", "-y", "-h"])   // commit's help
    }

    @Test func subcommandsAndHelpPassThrough() {
        #expect(gitNib("doctor") == ["doctor"])
        #expect(gitNib("hook", "install") == ["hook", "install"])
        #expect(gitNib("commit", "-y") == ["commit", "-y"])
        #expect(gitNib("generate") == ["generate"])
        #expect(gitNib("help") == ["help"])
        #expect(gitNib("help", "commit") == ["help", "commit"])
        #expect(gitNib("-h") == ["-h"])
        #expect(gitNib("--help") == ["--help"])
        #expect(gitNib("--version") == ["--version"])
    }

    /// `--plan` belongs to `nib generate`, the default subcommand.
    @Test func planGoesToGenerate() {
        #expect(gitNib("--plan") == ["--plan"])
    }
}

@Suite("git nib paths")
struct InvocationPathTests {
    @Test func hookUsesNibNextToGitNib() {
        let path = Invocation.hookBinaryPath(executable: "/opt/homebrew/bin/git-nib") { $0 == "/opt/homebrew/bin/nib" }
        #expect(path == "/opt/homebrew/bin/nib")
    }

    @Test func hookKeepsGitNibWhenThereIsNoNibNextToIt() {
        #expect(Invocation.hookBinaryPath(executable: "/tools/git-nib") { _ in false } == "/tools/git-nib")
    }

    @Test func hookKeepsNib() {
        #expect(Invocation.hookBinaryPath(executable: "/usr/local/bin/nib") { _ in true } == "/usr/local/bin/nib")
    }

    @Test func setupHintNamesTheDirectory() {
        #expect(Invocation.setupHint(nibDirectory: "/usr/local/bin") == "– not set up: ln -s nib /usr/local/bin/git-nib")
        // Without nib on PATH there's no directory to name; never suggest the current one.
        #expect(Invocation.setupHint(nibDirectory: nil) == "– not set up: put nib on PATH, then link git-nib next to it")
    }

    @Test func findsTheFirstMatchOnPath() {
        let found = Invocation.find("git-nib", inPath: "/usr/bin:/opt/homebrew/bin:/tools") {
            $0 == "/opt/homebrew/bin/git-nib" || $0 == "/tools/git-nib"
        }
        #expect(found == "/opt/homebrew/bin/git-nib")
        #expect(Invocation.find("git-nib", inPath: "/usr/bin:/bin") { _ in false } == nil)
    }
}
