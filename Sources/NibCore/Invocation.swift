import Foundation

/// nib also runs as `git-nib`, a link to the same binary, so `git nib` works as a git command.
public enum Invocation {
    /// The name git looks for on PATH when you type `git nib`.
    public static let gitCommandName = "git-nib"

    /// Turns `git nib …` into the nib arguments it stands for. `git nib` alone commits, like
    /// `nib commit`; subcommands, help and `--version` pass through, and so does `--plan`, which
    /// belongs to the default subcommand (`nib generate`). Anything else is an option for commit:
    /// `git nib -y` is `nib commit -y`.
    ///
    /// - Parameters:
    ///   - executable: `argv[0]`. Only its last path component matters.
    ///   - arguments: the arguments after `argv[0]`.
    ///   - passThrough: subcommand names that stay as they are (`commit`, `doctor`, `help`…).
    public static func arguments(executable: String, arguments: [String], passThrough: Set<String>) -> [String] {
        guard (executable as NSString).lastPathComponent == gitCommandName else { return arguments }
        guard let first = arguments.first else { return ["commit"] }
        if passThrough.contains(first) || ["-h", "--help", "--version", "--plan"].contains(first) {
            return arguments
        }
        return ["commit"] + arguments
    }

    /// The binary the git hook should call: `nib` itself, also when this run came in as `git-nib`,
    /// so the hook doesn't depend on the `git-nib` link.
    public static func hookBinaryPath(executable: String, isExecutable: (String) -> Bool) -> String {
        let url = URL(fileURLWithPath: executable)
        guard url.lastPathComponent == gitCommandName else { return executable }
        let sibling = url.deletingLastPathComponent().appendingPathComponent("nib").path
        return isExecutable(sibling) ? sibling : executable
    }

    /// What `nib doctor` suggests when `git-nib` isn't on PATH. `nibDirectory` is where `nib`
    /// was found on PATH, or nil when it isn't there either.
    public static func setupHint(nibDirectory: String?) -> String {
        guard let nibDirectory else { return "– not set up: put nib on PATH, then link git-nib next to it" }
        return "– not set up: ln -s nib \(URL(fileURLWithPath: nibDirectory).appendingPathComponent(gitCommandName).path)"
    }

    /// The first executable called `name` in a PATH-style list of directories.
    public static func find(_ name: String, inPath path: String, isExecutable: (String) -> Bool) -> String? {
        path.split(separator: ":").lazy
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name).path }
            .first(where: isExecutable)
    }
}
