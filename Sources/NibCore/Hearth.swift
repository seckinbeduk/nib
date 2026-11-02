import Foundation

// Hearth (github.com/seckinbeduk/hearth) runs a local model on your Mac and serves it with an
// OpenAI-compatible API. Apps that can't use Apple Intelligence, or prefer a bigger model, use it
// through this client. Each request names the app, so Hearth's "Who's using it" shows who used what.

/// Which model does the work.
public enum Engine: String, Sendable, CaseIterable, Codable {
    /// Apple Intelligence, on-device.
    case apple
    /// Hearth's local model.
    case hearth
    /// Apple Intelligence when it's available, Hearth otherwise.
    case auto
}

public enum HearthError: Error, LocalizedError, Equatable {
    case notRunning
    case server(String)
    case badReply

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Hearth isn't running. Start it from the menu bar, or get it at github.com/seckinbeduk/hearth."
        case .server(let message): "Hearth: \(message)"
        case .badReply: "Hearth's model didn't give a usable answer. Try again, or pick a larger model in Hearth."
        }
    }
}

public struct HearthClient: Sendable {
    public let baseURL: URL
    public let appName: String
    public let appVersion: String
    /// The model Hearth is serving, if it said.
    public let model: String?

    public init(baseURL: URL, appName: String, appVersion: String, model: String? = nil) {
        self.baseURL = baseURL
        self.appName = appName
        self.appVersion = appVersion
        self.model = model
    }

    /// Hearth's preferred port is 8800; if that's taken it uses one of the next nine.
    static func candidatePorts() -> [Int] {
        var ports = Array(8800...8809)
        if let preferred = CFPreferencesCopyAppValue("hearth.port" as CFString, "io.github.seckinbeduk.hearth" as CFString) as? Int,
           preferred > 0 {
            ports.removeAll { $0 == preferred }
            ports.insert(preferred, at: 0)
        }
        return ports
    }

    /// Finds a running Hearth on this Mac, or nil.
    public static func discover(appName: String, appVersion: String) async -> HearthClient? {
        for port in candidatePorts() {
            guard let base = URL(string: "http://127.0.0.1:\(port)") else { continue }
            var request = URLRequest(url: base.appendingPathComponent("health"))
            request.timeoutInterval = 0.5
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let health = try? JSONDecoder().decode(Health.self, from: data),
                  health.server == "Hearth" else { continue }
            return HearthClient(baseURL: base, appName: appName, appVersion: appVersion, model: health.model)
        }
        return nil
    }

    struct Health: Decodable {
        let status: String?
        let model: String?
        let server: String?
    }

    /// One chat completion, not streamed. Returns the text with any thinking removed.
    public func chat(system: String, user: String, maxTokens: Int, temperature: Double = 0.3) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(appName)/\(appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(appName, forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: "hearth",
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            max_tokens: maxTokens, temperature: temperature, stream: false
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw HearthError.notRunning
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.error.message
            throw HearthError.server(message ?? "request failed (\(status))")
        }
        guard let reply = try? JSONDecoder().decode(ChatReply.self, from: data),
              let content = reply.choices.first?.message.content else { throw HearthError.badReply }
        return JSONReply.removeThinking(content)
    }

    struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let max_tokens: Int
        let temperature: Double
        let stream: Bool
    }

    struct ChatReply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    struct ErrorReply: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}

/// Pulls a JSON object out of a model's reply, however it was wrapped.
public enum JSONReply {
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        let text = removeThinking(text)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text[start...end].utf8))
    }

    /// Drops a `<think>…</think>` block some local models emit before answering.
    public static func removeThinking(_ text: String) -> String {
        guard let close = text.range(of: "</think>") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// nib's model, served by Hearth. Local models can't be held to a schema, so the reply is
/// JSON in text, and MessageFormatter enforces the rules afterwards as usual.
public struct HearthCommitModel: CommitModel {
    let client: HearthClient

    public init(client: HearthClient) {
        self.client = client
    }

    /// Hearth's models take far more, but bigger prompts are slower; this keeps a commit quick.
    public var contextTokens: Int { 8_192 }

    public func tokenCount(_ text: String) async -> Int? { nil }

    public func respond(instructions: String, prompt: String) async throws -> String {
        try await client.chat(system: instructions, user: prompt, maxTokens: 300)
    }

    public func draft(instructions: String, prompt: String, imperativeEnglish: Bool) async throws -> CommitDraft {
        let system = instructions + """


        Reply with only a JSON object, no other text:
        {"bullets": ["..."], "subject": "...", "type": "...", "scope": "..."}
        """
        let reply = try await client.chat(system: system, user: prompt, maxTokens: 400)
        guard let draft = JSONReply.decode(Reply.self, from: reply), let subject = draft.subject, !subject.isEmpty else {
            throw HearthError.badReply
        }
        return CommitDraft(type: draft.type ?? "chore", scope: draft.scope ?? "", subject: subject, bullets: draft.bullets ?? [])
    }

    struct Reply: Decodable {
        var bullets: [String]?
        var subject: String?
        var type: String?
        var scope: String?
    }
}
