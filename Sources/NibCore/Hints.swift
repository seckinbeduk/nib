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

    /// The model's type, unless the paths say otherwise beyond doubt.
    public static func reconcile(modelType: String, suggested: String?) -> String {
        let suggested = suggested ?? ""
        switch suggested {
        case "docs", "test", "ci":
            return suggested
        case "feat" where ["refactor", "fix", "style", "perf"].contains(modelType.lowercased()):
            return "feat"   // brand-new files can't be refactored or fixed
        default:
            return modelType
        }
    }

    /// Anything under `docs/` is docs, build files there too (`docs/Makefile`, `docs/requirements.txt`).
    /// Elsewhere a build file is never docs, even with a docs-like name (`requirements.txt`, `CMakeLists.txt`).
    static func isDocs(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("docs/") || lower.contains("/docs/") { return true }
        if isBuild(path) { return false }
        let name = lower.split(separator: "/").last.map(String.init) ?? lower
        return [".md", ".mdx", ".rst", ".adoc", ".txt"].contains(where: { lower.hasSuffix($0) })
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
        // requirements-dev.txt, requirements_test.txt: pip files under another name.
        if name.hasPrefix("requirements"), name.hasSuffix(".txt") { return true }
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

    /// The most specific directory every changed file shares, e.g. `api` for `packages/api/src/*`
    /// and `nibcore` for `Sources/NibCore/*` plus `Tests/NibCoreTests/*`.
    public static func suggestedScope(for files: [FileDiff]) -> String? {
        guard let pick = sharedDirectories(scopeFiles(files)).last else { return nil }
        let scope = pick.replacingOccurrences(of: " ", with: "-")
        return scope.count <= 20 ? scope : nil
    }

    /// The model's scope, checked against the changed files. `suggested` is `suggestedScope(for: files)`.
    /// A scope is only replaced or dropped when it is clearly invented:
    /// - kept when it names a directory every file shares, the file every change is in, one of the
    ///   changed source files (`planner` for `Planner.swift`), or something the diff defines
    ///   (`enum Engine` → `engine`);
    /// - replaced by `suggested`, or dropped without one, when it is the name of a changed build
    ///   manifest (`package` from `Package.swift`): that names the file, not the change;
    /// - otherwise replaced by `suggested` when there is one, and kept when there isn't.
    /// An empty scope stays empty.
    public static func reconcileScope(modelScope: String, suggested: String?, files: [FileDiff]) -> String {
        let key = scopeKey(modelScope)
        guard !key.isEmpty else { return modelScope }
        let used = scopeFiles(files)

        if sharedDirectories(used).map(scopeKey).contains(key) { return modelScope }
        let stems = used.map { scopeKey(fileStem($0.path)) }
        if !stems.isEmpty, stems.allSatisfy({ $0 == key }) { return modelScope }
        // All files, not just `used`: a root manifest is left out of `used` but still names nothing.
        if files.contains(where: { isBuild($0.path) && manifestKey($0.path) == key }) { return suggested ?? "" }
        if stems.contains(key) || declares(key, in: used) { return modelScope }
        // A root manifest changed too, so the suggestion only describes part of the change
        // ("deps" for Package.swift + Sources/nib/Nib.swift isn't worse than "nib"): leave the model's scope.
        if files.count > used.count, files.contains(where: { isBuild($0.path) && !$0.path.contains("/") }) { return modelScope }
        return suggested ?? modelScope
    }

    /// Code files decide the scope; docs only when nothing else changed (README next to code is common).
    /// Build files count as code even when they look like docs (`requirements.txt`, `CMakeLists.txt`),
    /// but a manifest at the repo root (`Package.swift`) belongs to every module, so it only counts
    /// when nothing else is left: a new test target in `Package.swift` doesn't hide `Sources/nib`.
    static func scopeFiles(_ files: [FileDiff]) -> [FileDiff] {
        let code = files.filter { !isDocs($0.path) || isBuild($0.path) }
        let used = code.isEmpty ? files : code
        let nested = used.filter { !(isBuild($0.path) && !$0.path.contains("/")) }
        return nested.isEmpty ? used : nested
    }

    /// The common prefix of the files' meaningful directories: generic and hidden ones left out,
    /// Swift test targets folded into their module (`NibCoreTests` → `nibcore`), lowercased.
    static func sharedDirectories(_ files: [FileDiff]) -> [String] {
        let directories = files.map { meaningfulDirectories($0.path) }
        guard var common = directories.first else { return [] }
        for directory in directories.dropFirst() {
            common = zip(common, directory).prefix(while: { $0.0 == $0.1 }).map { $0.0 }
        }
        return common
    }

    static func meaningfulDirectories(_ path: String) -> [String] {
        path.split(separator: "/").dropLast().compactMap { part in
            let name = String(part)
            guard !name.hasPrefix("."), !genericDirectories.contains(name.lowercased()) else { return nil }
            return stripTestSuffix(name).lowercased()
        }
    }

    /// `Sources/NibCore/PlannerTests.swift` → `planner`.
    /// The scope key a build manifest's name suggests: `package` for `Package.swift`, and `requirement`
    /// for every pip file (`requirements-dev.txt` names the same thing as `requirements.txt`).
    static func manifestKey(_ path: String) -> String {
        let stem = fileStem(path)
        return scopeKey(stem.hasPrefix("requirements") ? "requirements" : stem)
    }

    static func fileStem(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        return stripTestSuffix(stem).lowercased()
    }

    static func stripTestSuffix(_ name: String) -> String {
        for suffix in ["Tests", "Test"] where name.count > suffix.count && name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// Lowercase, no separators, singular: `File-Paths` → `filepath`, `workflows` → `workflow`.
    static func scopeKey(_ text: String) -> String {
        let joined = text.lowercased().filter { !"-_./ ".contains($0) }
        return MessageFormatter.singular(joined)
    }

    /// Declaration keywords whose next word is a name the change is about. Not `let`, `var` or `case`:
    /// `let package = Package(` and `let model` are in almost every diff.
    static let declarationKeywords = [
        "enum", "struct", "class", "protocol", "actor", "extension", "typealias", "func",
        "interface", "type", "trait", "impl", "def", "fn", "module",
    ]

    /// Whether a non-noise file's hunks (headers and context included) declare a name whose scope key is `key`.
    /// Only hunks that roughly contain the key are searched with the regex, which keeps big diffs cheap.
    /// The key is singular and has no separators, so the precheck drops its last letter (`policy` must
    /// find `Policies`) and ignores underscores (`filepath` must find `file_path`).
    static func declares(_ key: String, in files: [FileDiff]) -> Bool {
        let pattern = "\\b(?:" + declarationKeywords.joined(separator: "|") + ")\\s+([A-Za-z_][A-Za-z0-9_]*)"
        guard let regex = try? Regex(pattern) else { return false }
        let needle = key.count > 3 ? String(key.dropLast()) : key
        for file in files where NoiseFilter.classify(file) == nil {
            for hunk in file.hunks where hunk.lowercased().filter({ $0 != "_" }).contains(needle) {
                for match in hunk.matches(of: regex) {
                    if let name = match.output[1].substring, scopeKey(String(name)) == key { return true }
                }
            }
        }
        return false
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
