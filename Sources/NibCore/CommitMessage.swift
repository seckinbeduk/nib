import Foundation

public enum CommitStyle: String, Sendable, CaseIterable {
    /// Match the repo: Conventional Commits if recent history uses them, plain otherwise.
    case auto
    /// `feat(api): add retry to upload client`
    case conventional
    /// `Add retry to upload client`
    case plain
}

/// What the model produces, before nib tidies it up.
public struct CommitDraft: Sendable, Equatable {
    public var type: String
    public var scope: String
    public var subject: String
    public var bullets: [String]

    public init(type: String, scope: String = "", subject: String, bullets: [String] = []) {
        self.type = type
        self.scope = scope
        self.subject = subject
        self.bullets = bullets
    }
}

/// Turns a draft into a message that follows git conventions, whatever the model did.
public enum MessageFormatter {
    public static let allowedTypes = ["feat", "fix", "refactor", "perf", "docs", "test", "build", "ci", "chore", "style", "revert"]
    public static let headerLimit = 72
    public static let bodyWidth = 72

    public static func format(_ draft: CommitDraft, style: CommitStyle, ticket: String? = nil) -> String {
        let subject = cleanSubject(draft.subject)
        let header: String
        if style == .plain {
            header = clip(capitalizeFirst(subject), to: headerLimit)
        } else {
            let type = allowedTypes.contains(draft.type.lowercased()) ? draft.type.lowercased() : "chore"
            let scope = cleanScope(draft.scope)
            let prefix = type + (scope.isEmpty ? "" : "(\(scope))") + ": "
            header = prefix + clip(lowercaseFirst(subject), to: headerLimit - prefix.count)
        }

        var seen: Set<String> = [subject.lowercased()]
        var bullets: [String] = []
        for raw in draft.bullets {
            let bullet = cleanBullet(raw)
            guard !bullet.isEmpty, seen.insert(bullet.lowercased()).inserted else { continue }
            bullets.append(bullet)
        }

        var message = header
        if !bullets.isEmpty {
            message += "\n\n" + bullets.map { wrap("- " + $0, width: bodyWidth, indent: "  ") }.joined(separator: "\n")
        }
        if let ticket, !message.contains(ticket) {
            message += "\n\nRefs: \(ticket)"
        }
        return message
    }

    // MARK: - Cleanup

    static func cleanSubject(_ raw: String) -> String {
        var subject = collapseWhitespace(raw.components(separatedBy: .newlines).first ?? raw)
        subject = subject.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’ "))
        // The model sometimes repeats the type inside the subject: "feat: add x".
        if let regex = try? Regex("^[a-zA-Z]+(\\([^)]*\\))?!?:\\s*"), let match = subject.prefixMatch(of: regex) {
            let type = subject[match.range].prefix { $0.isLetter }.lowercased()
            if allowedTypes.contains(type) { subject = String(subject[match.range.upperBound...]) }
        }
        while let last = subject.last, ".!;:,".contains(last) { subject.removeLast() }
        return subject.trimmingCharacters(in: .whitespaces)
    }

    static func cleanScope(_ raw: String) -> String {
        let scope = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            .replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-_./"))
        guard !scope.isEmpty, scope.count <= 24, scope.unicodeScalars.allSatisfy(allowed.contains),
              !["none", "n/a", "null", "general", "misc", "all", "root"].contains(scope),
              !Hints.genericDirectories.contains(scope) else { return "" }
        return scope
    }

    static func cleanBullet(_ raw: String) -> String {
        var bullet = collapseWhitespace(raw)
        while let first = bullet.first, "-*•·–".contains(first) || first == " " { bullet.removeFirst() }
        bullet = bullet.trimmingCharacters(in: .whitespaces)
        while bullet.hasSuffix(".") && !bullet.hasSuffix("..") { bullet.removeLast() }
        return capitalizeFirst(bullet)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func lowercaseFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep acronyms and identifiers: "API", "URLSession", "iOS".
        let second = text.dropFirst().first
        if first.isUppercase, let second, second.isUppercase || second.isNumber { return text }
        return first.lowercased() + text.dropFirst()
    }

    static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    static let danglingWords: Set<String> = [
        "a", "an", "the", "and", "or", "with", "for", "to", "of", "in", "on", "at", "by", "from", "into", "via", "as", "its", "their",
    ]

    /// Shortens to `limit` at a phrase boundary: "generation with style detection" becomes
    /// "generation", not "generation with style".
    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var words = text.prefix(limit).split(separator: " ").map(String.init)
        let cutMidWord = text[text.index(text.startIndex, offsetBy: limit)] != " "
        if cutMidWord, words.count > 1 { words.removeLast() }
        // Drop the trailing phrase that lost its end, if that still leaves most of the line.
        if let start = words.lastIndex(where: { danglingWords.contains($0.lowercased()) }), start >= max(2, words.count / 2) {
            words = Array(words[..<start])
        }
        while words.count > 2, let last = words.last, danglingWords.contains(last.lowercased()) {
            words.removeLast()
        }
        let clipped = words.joined(separator: " ")
        return clipped.count <= limit ? clipped : String(clipped.prefix(limit))
    }

    /// Wraps at `width`, continuing lines with `indent`.
    static func wrap(_ text: String, width: Int, indent: String) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = indent + word
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}
