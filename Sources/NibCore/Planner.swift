import Foundation

/// How a staged diff will be fed to the model.
public struct Plan: Sendable, Equatable {
    public enum Mode: String, Sendable {
        /// The whole diff fits in one prompt.
        case single
        /// Each chunk is summarized on its own, then the summaries are combined.
        case mapReduce = "map-reduce"
    }

    public var mode: Mode
    /// Diff text, each piece small enough for one prompt.
    public var chunks: [String]
    /// A compact list of every changed file with its stats. Always shown to the model.
    public var overview: String
    /// Files listed in the overview but never sent as content.
    public var noise: [NoisyFile]
    /// Files left out of the detailed analysis because the diff was too big.
    public var omitted: [String]
    /// The character budget the plan was made for.
    public var budgetChars: Int
}

public struct NoisyFile: Sendable, Equatable {
    public var path: String
    public var kind: NoiseKind
}

public enum Planner {
    /// Splits the diff into prompt-sized chunks.
    /// - Parameters:
    ///   - budgetChars: The most diff text one prompt can carry.
    ///   - maxChunks: Caps the number of model calls; whatever doesn't fit is listed as omitted.
    public static func plan(_ files: [FileDiff], budgetChars: Int, maxChunks: Int = 8) -> Plan {
        let budget = max(budgetChars, 400)
        var noise: [NoisyFile] = []
        var signal: [FileDiff] = []
        for file in files {
            if let kind = NoiseFilter.classify(file) {
                noise.append(NoisyFile(path: file.path, kind: kind))
            } else {
                signal.append(file)
            }
        }

        let overview = overview(files, maxChars: budget / 4)
        let sections = signal.map(render)
        let total = sections.reduce(0) { $0 + $1.count + 2 }

        if total + overview.count <= budget {
            return Plan(mode: .single, chunks: sections.isEmpty ? [] : [sections.joined(separator: "\n\n")],
                        overview: overview, noise: noise, omitted: [], budgetChars: budget)
        }

        // Too big for one prompt: cut big files into hunk-sized pieces, then pack the pieces
        // into chunks, most-changed files first so they're the last to be dropped.
        var pieces: [Piece] = []
        for (index, file) in signal.enumerated() {
            for text in split(file, section: sections[index], budget: budget) {
                pieces.append(Piece(path: file.path, text: text, weight: file.changedLines, order: pieces.count))
            }
        }
        pieces.sort { ($0.weight, -$0.order) > ($1.weight, -$1.order) }

        var bins: [[Piece]] = []
        var sizes: [Int] = []
        var omitted: [String] = []
        for piece in pieces {
            let cost = piece.text.count + 2
            if let slot = sizes.firstIndex(where: { $0 + cost <= budget }) {
                bins[slot].append(piece)
                sizes[slot] += cost
            } else if bins.count < maxChunks {
                bins.append([piece])
                sizes.append(cost)
            } else if !omitted.contains(piece.path) {
                omitted.append(piece.path)
            }
        }

        // Within a chunk, keep the order the files had in the diff.
        let chunks = bins.map { bin in
            bin.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n\n")
        }
        return Plan(mode: .mapReduce, chunks: chunks, overview: overview, noise: noise,
                    omitted: omitted, budgetChars: budget)
    }

    struct Piece {
        var path: String
        var text: String
        var weight: Int
        var order: Int
    }

    // MARK: - Rendering

    static func header(_ file: FileDiff) -> String {
        "### \(file.displayPath) (\(file.status.rawValue), +\(file.additions) −\(file.deletions))"
    }

    /// One file as the model sees it.
    static func render(_ file: FileDiff) -> String {
        if isOutlined(file) { return outline(file) }
        switch file.status {
        case .deleted:
            // The removed content costs tokens and rarely explains anything.
            return "### \(file.path) (deleted, −\(file.deletions) lines)"
        case .renamed where file.hunks.isEmpty, .copied where file.hunks.isEmpty:
            return "### \(file.displayPath) (\(file.status.rawValue), no content changes)"
        default:
            return ([header(file)] + file.hunks).joined(separator: "\n")
        }
    }

    // MARK: - Outlines

    /// New files longer than this are sent as an outline. Reading every line of a new file costs
    /// the on-device model seconds per thousand tokens, and its declarations say what it's for.
    public static let outlineThreshold = 40
    static let outlineLimit = 60

    static func isOutlined(_ file: FileDiff) -> Bool {
        file.status == .added && file.additions > outlineThreshold
    }

    nonisolated(unsafe) static let declaration = try? Regex(
        #"^\s*(@\w+(\([^)]*\))?\s+)*((public|private|internal|fileprivate|open|static|final|override|mutating|nonisolated|async|export|default|pub|abstract|protected|package)\s+)*(func|init|deinit|struct|class|enum|protocol|extension|actor|typealias|def|interface|type|fn|fun|impl|trait|function|module|object|record|macro)(?=[\s(<])"#
    )

    /// The skeleton of a new file: declarations, the first line of each doc comment, Markdown headings.
    static func outline(_ file: FileDiff) -> String {
        let markdown = [".md", ".mdx", ".rst"].contains { file.path.lowercased().hasSuffix($0) }
        var kept: [String] = []
        var inDocBlock = false
        var added: [String] = []
        for hunk in file.hunks {
            for line in hunk.split(separator: "\n") where line.hasPrefix("+") {
                let code = line.dropFirst()
                added.append(String(code))
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                let isDoc = trimmed.hasPrefix("///") || trimmed.hasPrefix("/**") || trimmed.hasPrefix("\"\"\"")
                defer { inDocBlock = isDoc }
                if markdown {
                    if trimmed.hasPrefix("#") { kept.append(String(code)) }
                } else if isDoc {
                    if !inDocBlock { kept.append(String(code)) }
                } else if let regex = declaration, code.prefixMatch(of: regex) != nil {
                    kept.append(String(code))
                }
            }
        }
        var lines = ["### \(file.path) (new file, \(file.additions) lines, outline)"]
        if kept.isEmpty {
            lines += added.prefix(15)
            if added.count > 15 { lines.append("… (\(added.count - 15) more lines)") }
        } else {
            lines += kept.prefix(outlineLimit)
            if kept.count > outlineLimit { lines.append("… (\(kept.count - outlineLimit) more declarations)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Cuts one oversized file into pieces at hunk boundaries; a single huge hunk gets truncated.
    static func split(_ file: FileDiff, section: String, budget: Int) -> [String] {
        guard section.count > budget else { return [section] }
        if isOutlined(file) { return [truncate(section, to: budget)] }
        let headerRoom = header(file).count + 16   // room for " — part 2/3"
        let limit = max(budget - headerRoom, 200)

        var bodies: [String] = []
        var current = ""
        for hunk in file.hunks {
            let hunk = hunk.count > limit ? truncate(hunk, to: limit) : hunk
            if current.isEmpty {
                current = hunk
            } else if current.count + 1 + hunk.count <= limit {
                current += "\n" + hunk
            } else {
                bodies.append(current)
                current = hunk
            }
        }
        if !current.isEmpty { bodies.append(current) }
        if bodies.isEmpty { return [truncate(section, to: budget)] }

        return bodies.enumerated().map { index, body in
            let part = bodies.count > 1 ? " — part \(index + 1)/\(bodies.count)" : ""
            return header(file) + part + "\n" + body
        }
    }

    /// Keeps the start and the end of `text`, dropping lines in the middle.
    public static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let available = max(limit - 40, 0)

        var head: [String] = []
        var used = 0
        for line in lines {
            if used + line.count + 1 > available * 7 / 10 { break }
            head.append(line)
            used += line.count + 1
        }
        var tail: [String] = []
        var tailUsed = 0
        for line in lines[head.count...].reversed() {
            if tailUsed + line.count + 1 > available - used { break }
            tail.insert(line, at: 0)
            tailUsed += line.count + 1
        }
        if head.isEmpty && tail.isEmpty { return String(text.prefix(limit)) }

        let omitted = lines.count - head.count - tail.count
        let result = (head + ["… (\(omitted) lines omitted) …"] + tail).joined(separator: "\n")
        return result.count <= limit ? result : String(result.prefix(limit))
    }

    /// `M Sources/App.swift (+12 −3)`, one line per file, capped at `maxChars`.
    public static func overview(_ files: [FileDiff], maxChars: Int) -> String {
        var lines: [String] = []
        var used = 0
        for (index, file) in files.enumerated() {
            var line = "\(file.statusLetter) \(file.displayPath)"
            if let kind = NoiseFilter.classify(file) {
                line += kind == .binary ? " (binary)" : " (+\(file.additions) −\(file.deletions), \(kind.rawValue), not analyzed)"
            } else {
                line += " (+\(file.additions) −\(file.deletions))"
            }
            if used + line.count + 1 > maxChars, !lines.isEmpty {
                lines.append("… and \(files.count - index) more files")
                break
            }
            lines.append(line)
            used += line.count + 1
        }
        return lines.joined(separator: "\n")
    }
}
