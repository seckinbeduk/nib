import Foundation

/// Everything nib says to the model. Kept short on purpose: the on-device context is small.
public enum Prompts {
    public static func summarizeInstructions(language: String?) -> String {
        """
        You review part of a git diff. Lines starting with + were added, lines starting with - were removed.
        For each file, write one to three short bullet points saying what changed and, when the code makes it clear, why.
        Name the functions, types and settings involved. Don't mention line numbers. Don't guess beyond the diff.
        \(languageLine(language))
        """
    }

    public static func composeInstructions(language: String?) -> String {
        """
        You write git commit messages from staged changes.
        type: the kind of change, one of feat, fix, refactor, perf, docs, test, build, ci, chore, style.
        scope: a short lowercase name for the area changed, or empty.
        subject: imperative mood, at most 60 characters, no period. Example: "add retry to the upload client".
        bullets: up to 4 short points on the important changes and why. Leave empty for a small change.
        Describe the intent of the change as a whole, not every file. Never mention changes that aren't there.
        \(languageLine(language))
        """
    }

    public static func composePrompt(overview: String, diff: String?, hints: [String]) -> String {
        var prompt = "Changed files:\n\(overview)"
        if let diff, !diff.isEmpty { prompt += "\n\nDiff:\n\(diff)" }
        if !hints.isEmpty { prompt += "\n\n" + hints.joined(separator: "\n") }
        return prompt
    }

    public static func reducePrompt(overview: String, summaries: [String], hints: [String]) -> String {
        var prompt = "Changed files:\n\(overview)\n\nWhat changed:\n" + summaries.joined(separator: "\n")
        if !hints.isEmpty { prompt += "\n\n" + hints.joined(separator: "\n") }
        return prompt
    }

    public static func condenseInstructions(language: String?) -> String {
        """
        Merge these notes about one set of code changes into at most six bullet points.
        Keep the most important changes and drop repetition.
        \(languageLine(language))
        """
    }

    public static func hintLines(type: String?, scope: String?) -> [String] {
        var lines: [String] = []
        if let type { lines.append("Hint: the paths suggest the type is \"\(type)\".") }
        if let scope { lines.append("Hint: every change is under \"\(scope)\", a good scope.") }
        return lines
    }

    static func languageLine(_ language: String?) -> String {
        guard let language, !isEnglish(language) else { return "Write in English." }
        return "Write in \(language). Keep code identifiers as they are."
    }

    public static func isEnglish(_ language: String) -> Bool {
        ["en", "english"].contains(language.lowercased()) || language.lowercased().hasPrefix("en-") || language.lowercased().hasPrefix("en_")
    }

    /// `tr` → `Turkish`; full names pass through.
    public static func languageName(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { return nil }
        if code.count <= 3 || code.contains("-") || code.contains("_") {
            let base = String(code.prefix { $0.isLetter })
            if let name = Locale(identifier: "en").localizedString(forLanguageCode: base), name.lowercased() != base.lowercased() {
                return name
            }
        }
        return code
    }
}
