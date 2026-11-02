import Foundation

/// Cheap, deterministic guesses that steer a small model toward the right answer.
public enum Hints {
    // MARK: Commit type

    /// A Conventional Commits type when the file paths alone make it obvious.
    public static func suggestedType(for files: [FileDiff]) -> String? {
        let paths = files.map(\.path)
        guard !paths.isEmpty else { return nil }
        if paths.allSatisfy(isDocs) { return "docs" }
        if paths.allSatisfy(isTest) { return "test" }
        if paths.allSatisfy(isCI) { return "ci" }
        if paths.allSatisfy(isBuild) { return "build" }
        // Only new files: something is being added, whatever the model thinks it looks like.
        if files.allSatisfy({ $0.status == .added }) { return "feat" }
        return nil
    }

    static func isDocs(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = lower.split(separator: "/").last.map(String.init) ?? lower
        return lower.hasPrefix("docs/") || lower.contains("/docs/")
            || [".md", ".mdx", ".rst", ".adoc", ".txt"].contains(where: { lower.hasSuffix($0) })
            || ["license", "authors", "contributors"].contains(name)
    }

    static func isTest(_ path: String) -> Bool {
        let lower = path.lowercased()
        let components = lower.split(separator: "/").map(String.init)
        let name = components.last ?? lower
        if components.dropLast().contains(where: { ["test", "tests", "__tests__", "spec", "specs"].contains($0) }) { return true }
        if components.dropLast().contains(where: { $0.hasSuffix("tests") }) { return true }   // Swift: FooTests/
        return name.hasSuffix("tests.swift") || name.hasSuffix("test.swift") || name.hasSuffix("_test.go")
            || name.contains(".test.") || name.contains(".spec.") || name.hasPrefix("test_") || name.hasSuffix("_test.py")
    }

    static func isCI(_ path: String) -> Bool {
        path.hasPrefix(".github/workflows/") || path.hasPrefix(".circleci/") || path == ".gitlab-ci.yml"
            || path == "Jenkinsfile" || path == "azure-pipelines.yml" || path == ".travis.yml" || path.hasPrefix(".buildkite/")
    }

    static func isBuild(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return NoiseFilter.lockfiles.contains(name) || [
            "Package.swift", "package.json", "Podfile", "Gemfile", "Cargo.toml", "go.mod", "pyproject.toml",
            "requirements.txt", "build.gradle", "build.gradle.kts", "pom.xml", "Makefile", "CMakeLists.txt", "project.yml",
        ].contains(name)
    }

    // MARK: Scope

    static let genericDirectories: Set<String> = [
        "sources", "source", "src", "lib", "libs", "app", "apps", "packages", "pkg", "internal", "cmd",
        "tests", "test", "spec", "main", "java", "kotlin", "swift", "public", "resources", "components",
    ]

    /// The most specific directory every changed file shares, e.g. `api` for `packages/api/src/*`.
    public static func suggestedScope(for files: [FileDiff]) -> String? {
        let directories = files.map { Array($0.path.split(separator: "/").map(String.init).dropLast()) }
        guard var common = directories.first, !common.isEmpty else { return nil }
        for directory in directories.dropFirst() {
            common = zip(common, directory).prefix(while: { $0.0 == $0.1 }).map { $0.0 }
            if common.isEmpty { return nil }
        }
        guard let pick = common.reversed().first(where: { !genericDirectories.contains($0.lowercased()) && !$0.hasPrefix(".") })
        else { return nil }
        let scope = pick.lowercased().replacingOccurrences(of: " ", with: "-")
        return scope.count <= 20 ? scope : nil
    }

    // MARK: Ticket

    /// `JIRA-123` from a branch like `feature/JIRA-123-add-login`.
    public static func ticket(fromBranch branch: String?) -> String? {
        guard let branch, let regex = try? Regex("[A-Z][A-Z0-9]{1,9}-[0-9]+") else { return nil }
        guard let match = branch.firstMatch(of: regex) else { return nil }
        return String(branch[match.range])
    }

    // MARK: Style

    /// Conventional Commits if the repo already uses them; plain sentences if it clearly doesn't.
    public static func detectStyle(recentSubjects: [String]) -> CommitStyle {
        let subjects = recentSubjects.filter { !$0.hasPrefix("Merge ") && !$0.isEmpty }
        guard subjects.count >= 3, let regex = try? Regex("^[a-z]+(\\([^)]+\\))?!?: ") else { return .conventional }
        let conventional = subjects.filter { $0.prefixMatch(of: regex) != nil }.count
        return conventional * 2 >= subjects.count ? .conventional : .plain
    }
}
