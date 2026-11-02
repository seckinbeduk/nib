import Foundation

/// The `prepare-commit-msg` hook that puts nib's message in your editor.
public enum Hook {
    public static let name = "prepare-commit-msg"
    public static let marker = "# nib-managed-hook"

    /// The hook script. It never blocks a commit: on any problem you get your usual empty editor.
    public static func script(binaryPath: String) -> String {
        """
        #!/bin/sh
        \(marker)
        # nib writes your commit message on-device with Apple Intelligence.
        # https://github.com/seckinbeduk/nib
        # Remove with `nib hook uninstall`.

        # Only for a plain `git commit`. $2 is set for -m, -F, templates, merges, squashes and amends.
        [ -n "$2" ] && exit 0

        NIB="\(binaryPath)"
        [ -x "$NIB" ] || NIB="$(command -v nib 2>/dev/null)"
        [ -n "$NIB" ] || exit 0

        "$NIB" hook run "$1" || true
        exit 0

        """
    }

    public static func isManaged(_ contents: String) -> Bool {
        contents.contains(marker)
    }

    public enum InstallResult: Equatable, Sendable {
        case installed
        case replaced(backup: String)
    }

    /// Writes the hook into `directory`. An existing hook that isn't nib's is kept as a backup, and only with `force`.
    public static func install(in directory: URL, binaryPath: String, force: Bool) throws -> InstallResult {
        let fileManager = FileManager.default
        let url = directory.appendingPathComponent(name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var result = InstallResult.installed
        if let existing = try? String(contentsOf: url, encoding: .utf8), !isManaged(existing) {
            guard force else { throw NibError.hookExists(url.path) }
            let backup = directory.appendingPathComponent(name + ".nib-backup")
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: url, to: backup)
            result = .replaced(backup: backup.path)
        }
        try script(binaryPath: binaryPath).write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return result
    }

    /// Removes nib's hook and restores a backed-up one. Returns false if nib's hook wasn't there.
    @discardableResult
    public static func uninstall(from directory: URL) throws -> Bool {
        let fileManager = FileManager.default
        let url = directory.appendingPathComponent(name)
        guard let existing = try? String(contentsOf: url, encoding: .utf8), isManaged(existing) else { return false }
        try fileManager.removeItem(at: url)
        let backup = directory.appendingPathComponent(name + ".nib-backup")
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.moveItem(at: backup, to: url)
        }
        return true
    }

    /// Puts `message` at the top of the commit message file git prepared.
    /// Returns nil when the file already has a message (a template, say), which nib leaves alone.
    public static func merge(message: String, into existing: String, commentChar: Character = "#") -> String? {
        let hasMessage = existing.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.first != commentChar
        }
        guard !hasMessage else { return nil }

        var result = message + "\n"
        if commentChar == "#" {
            result += "# ✎ Written on-device by nib with Apple Intelligence. Edit freely.\n"
        }
        let rest = existing.drop { $0 == "\n" }
        return rest.isEmpty ? result : result + "\n" + rest
    }
}
