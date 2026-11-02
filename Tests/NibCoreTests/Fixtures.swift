import Foundation
@testable import NibCore

/// Builds `git diff` output for tests.
enum Fixture {
    static func modified(_ path: String, removed: [String] = ["old line"], added: [String] = ["new line"]) -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..2222222 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -1,\(removed.count + 1) +1,\(added.count + 1) @@
         context
        \(removed.map { "-" + $0 }.joined(separator: "\n"))
        \(added.map { "+" + $0 }.joined(separator: "\n"))
        """
    }

    static func added(_ path: String, lines: [String]) -> String {
        """
        diff --git a/\(path) b/\(path)
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/\(path)
        @@ -0,0 +1,\(lines.count) @@
        \(lines.map { "+" + $0 }.joined(separator: "\n"))
        """
    }

    static func deleted(_ path: String, lines: Int) -> String {
        """
        diff --git a/\(path) b/\(path)
        deleted file mode 100644
        index 4444444..0000000
        --- a/\(path)
        +++ /dev/null
        @@ -1,\(lines) +0,0 @@
        \((0..<lines).map { "-line \($0)" }.joined(separator: "\n"))
        """
    }

    /// One file with `hunks` hunks of `linesPerHunk` added lines each.
    static func big(_ path: String, hunks: Int, linesPerHunk: Int) -> String {
        var text = "diff --git a/\(path) b/\(path)\nindex 5555555..6666666 100644\n--- a/\(path)\n+++ b/\(path)\n"
        for hunk in 0..<hunks {
            let start = hunk * 100 + 1
            text += "@@ -\(start),1 +\(start),\(linesPerHunk + 1) @@ func f\(hunk)()\n context\n"
            text += (0..<linesPerHunk).map { "+    let value\(hunk)_\($0) = compute(\($0))" }.joined(separator: "\n") + "\n"
        }
        return text
    }

    static func files(_ diffs: String...) -> [FileDiff] {
        DiffParser.parse(diffs.joined(separator: "\n"))
    }
}

/// A model that answers instantly and records what it was asked.
final class FakeModel: CommitModel, @unchecked Sendable {
    var contextTokens = 4_096
    var charsPerToken: Double? = nil
    var draftResult = CommitDraft(type: "feat", scope: "", subject: "add the thing", bullets: [])
    /// Errors to throw from the next calls, in order.
    var respondErrors: [Error] = []
    var draftErrors: [Error] = []

    private let lock = NSLock()
    private(set) var respondPrompts: [String] = []
    private(set) var draftPrompts: [String] = []

    func tokenCount(_ text: String) async -> Int? {
        charsPerToken.map { Int(Double(text.count) / $0) }
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        try lock.withLock {
            respondPrompts.append(prompt)
            if !respondErrors.isEmpty { throw respondErrors.removeFirst() }
            return "- summary of part \(respondPrompts.count)"
        }
    }

    private(set) var imperativeFlags: [Bool] = []

    func draft(instructions: String, prompt: String, imperativeEnglish: Bool) async throws -> CommitDraft {
        try lock.withLock {
            draftPrompts.append(prompt)
            imperativeFlags.append(imperativeEnglish)
            if !draftErrors.isEmpty { throw draftErrors.removeFirst() }
            return draftResult
        }
    }
}
