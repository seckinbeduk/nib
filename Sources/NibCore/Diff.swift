import Foundation

/// One file's worth of a unified git diff.
public struct FileDiff: Equatable, Sendable {
    public enum Status: String, Sendable {
        case added, deleted, modified, renamed, copied
    }

    public var path: String
    public var oldPath: String?
    public var status: Status
    public var isBinary: Bool
    public var additions: Int
    public var deletions: Int
    /// The hunks, each one starting with its `@@` line.
    public var hunks: [String]

    public init(path: String, oldPath: String? = nil, status: Status = .modified, isBinary: Bool = false,
                additions: Int = 0, deletions: Int = 0, hunks: [String] = []) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.isBinary = isBinary
        self.additions = additions
        self.deletions = deletions
        self.hunks = hunks
    }

    public var changedLines: Int { additions + deletions }

    /// A one-letter status like `git status --short`.
    public var statusLetter: String {
        switch status {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        case .copied: "C"
        }
    }

    /// `Sources/App.swift` or `Old.swift → New.swift`.
    public var displayPath: String {
        if let oldPath, oldPath != path { return "\(oldPath) → \(path)" }
        return path
    }
}

/// Parses the output of `git diff` (unified format, `a/` and `b/` prefixes).
public enum DiffParser {
    public static func parse(_ raw: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: [String] = []
        var inHunks = false

        func flushHunk() {
            if !hunk.isEmpty {
                current?.hunks.append(hunk.joined(separator: "\n"))
                hunk = []
            }
        }
        func flushFile() {
            flushHunk()
            if let file = current { files.append(file) }
            current = nil
            inHunks = false
        }

        for sub in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(sub)

            if line.hasPrefix("diff --git ") {
                flushFile()
                current = FileDiff(path: pathFromHeader(line))
                continue
            }
            guard current != nil else { continue }

            if inHunks {
                // Inside hunks, "---" / "+++" are content, not headers.
                if line.hasPrefix("@@") {
                    flushHunk()
                    hunk = [line]
                } else if !line.isEmpty {
                    if line.hasPrefix("+") { current!.additions += 1 }
                    else if line.hasPrefix("-") { current!.deletions += 1 }
                    hunk.append(line)
                }
                continue
            }

            if line.hasPrefix("@@") {
                inHunks = true
                hunk = [line]
            } else if line.hasPrefix("new file mode") {
                current!.status = .added
            } else if line.hasPrefix("deleted file mode") {
                current!.status = .deleted
            } else if line.hasPrefix("rename from ") {
                current!.oldPath = cleanPath(String(line.dropFirst("rename from ".count)))
                current!.status = .renamed
            } else if line.hasPrefix("rename to ") {
                current!.path = cleanPath(String(line.dropFirst("rename to ".count)))
            } else if line.hasPrefix("copy from ") {
                current!.oldPath = cleanPath(String(line.dropFirst("copy from ".count)))
                current!.status = .copied
            } else if line.hasPrefix("copy to ") {
                current!.path = cleanPath(String(line.dropFirst("copy to ".count)))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                current!.isBinary = true
            } else if line.hasPrefix("+++ ") {
                let path = stripPrefix(cleanPath(String(line.dropFirst(4))), "b/")
                if path != "/dev/null" { current!.path = path }
            }
        }
        flushFile()
        return files
    }

    /// `diff --git a/X b/X` → `X`, even when X contains spaces.
    static func pathFromHeader(_ line: String) -> String {
        let rest = String(line.dropFirst("diff --git ".count))
        let chars = Array(rest)
        // For an unrenamed file the header is "a/" + X + " b/" + X, so X has a known length.
        if rest.hasPrefix("a/"), (chars.count - 5) > 0, (chars.count - 5) % 2 == 0 {
            let length = (chars.count - 5) / 2
            let first = String(chars[2..<(2 + length)])
            let separator = String(chars[(2 + length)..<(5 + length)])
            let second = String(chars[(5 + length)...])
            if separator == " b/", first == second { return first }
        }
        if let range = rest.range(of: " b/", options: .backwards) {
            return cleanPath(String(rest[range.upperBound...]))
        }
        return cleanPath(rest)
    }

    static func cleanPath(_ path: String) -> String {
        var path = path
        while path.hasSuffix("\t") { path.removeLast() }
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            path = String(path.dropFirst().dropLast())
        }
        return path
    }

    static func stripPrefix(_ path: String, _ prefix: String) -> String {
        path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
