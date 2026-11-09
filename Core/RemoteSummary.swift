import Foundation

// Takeaways written by a language model the user has an account with, for a device that has no
// on-device one (Apple Intelligence is not offered everywhere). Pure request building and answer
// reading, so what is sent and what is kept can be tested; the call is at the bottom, over a session
// the tests replace.

enum SummaryProvider: String, Codable, CaseIterable {
    case anthropic, openai

    var name: String { self == .anthropic ? "Claude" : "ChatGPT" }

    /// Who runs it, which is who receives what is sent.
    var company: String { self == .anthropic ? "Anthropic" : "OpenAI" }

    /// Anthropic's most capable current model is the default; the model is the user's to change
    /// (a smaller one costs far less per summary, and a summary is a small task).
    var defaultModel: String { self == .anthropic ? "claude-opus-5-5" : "gpt-4o-mini" }
}

/// What the user set up in Tune. The whole value, key included, lives in the Keychain.
struct RemoteSummaryConfig: Codable, Equatable {
    var provider: SummaryProvider
    var key: String
    var model: String

    var modelOrDefault: String {
        let m = model.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? provider.defaultModel : m
    }
}

enum RemoteSummaryError: Error, CustomStringConvertible {
    case refused
    case slowDown
    case server(Int)
    case unreadable

    var description: String {
        switch self {
        case .refused: return "The key was refused. Check it, the model name, and that the account has credit."
        case .slowDown: return "The service asked to slow down."
        case .server(let code): return "The service answered with an error (\(code))."
        case .unreadable: return "The service's answer could not be read."
        }
    }
}

enum RemoteSummary {
    /// The same brief the on-device model gets: findings only, nothing the abstract does not say.
    static let instructions = """
        You write the takeaway of a research paper for a scientist scrolling a feed. \
        In one or two sentences, at most 45 words, say what the study found or shows, \
        in plain and specific terms. Use only what the abstract states: add no background, \
        no opinion, and no number or claim that is not in it. If the abstract reports no \
        result, say in one sentence what the paper does. Reply with those sentences only, as one paragraph.
        """

    static func prompt(title: String, abstract: String) -> String {
        "Title: \(title)\n\nAbstract: \(String(abstract.prefix(3000)))"
    }

    /// The effort setting exists on the current Claude generation only; an older model rejects it.
    static func supportsEffort(_ model: String) -> Bool {
        model.range(of: #"^claude-(opus|sonnet|haiku|fable|mythos)-5(-\d+)?$"#, options: .regularExpression) != nil
    }

    static func request(_ config: RemoteSummaryConfig, title: String, abstract: String) -> URLRequest {
        request(config, system: instructions, user: prompt(title: title, abstract: abstract))
    }

    /// Any one question to the service the user set up: a brief and a message. The only two things
    /// that leave the device are in it, so what is sent is what a test can read.
    static func request(_ config: RemoteSummaryConfig, system: String, user: String) -> URLRequest {
        let model = config.modelOrDefault
        var r: URLRequest
        var body: [String: Any]
        switch config.provider {
        case .anthropic:
            r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            r.setValue(config.key, forHTTPHeaderField: "x-api-key")
            r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            // No temperature or top_p: current models reject them. The room is generous because a
            // model that thinks counts its thinking against it; the effort is low because this is a
            // summary of a paragraph.
            body = ["model": model, "max_tokens": 4000, "system": system,
                    "messages": [["role": "user", "content": user]]]
            if supportsEffort(model) { body["output_config"] = ["effort": "low"] }
        case .openai:
            r = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            r.setValue("Bearer " + config.key, forHTTPHeaderField: "Authorization")
            body = ["model": model, "max_completion_tokens": 2000,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    /// The text of an answer, nil when the model declined to answer (a refusal, an empty reply).
    static func text(from data: Data, provider: SummaryProvider) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch provider {
        case .anthropic:
            if (o["stop_reason"] as? String) == "refusal" { return nil }
            let blocks = (o["content"] as? [[String: Any]]) ?? []
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            return text.isEmpty ? nil : text
        case .openai:
            let message = ((o["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
            if message?["refusal"] is String { return nil }
            return (message?["content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// The text of the service's answer to one question, nil when it declined; throws when the call
    /// failed, so the user can be told why.
    static func answer(_ config: RemoteSummaryConfig, system: String, user: String,
                       session: URLSession = .shared) async throws -> String? {
        let (data, response) = try await session.data(for: request(config, system: system, user: user))
        guard let http = response as? HTTPURLResponse else { throw RemoteSummaryError.unreadable }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403, 404: throw RemoteSummaryError.refused
        case 429, 529: throw RemoteSummaryError.slowDown
        default: throw RemoteSummaryError.server(http.statusCode)
        }
        return text(from: data, provider: config.provider)
    }

    /// One takeaway, cleaned and held to two sentences like the on-device one. nil when the model
    /// declined; throws when the call failed, so the user can be told why nothing arrives.
    static func takeaway(_ config: RemoteSummaryConfig, title: String, abstract: String,
                         session: URLSession = .shared) async throws -> String? {
        try await answer(config, system: instructions, user: prompt(title: title, abstract: abstract), session: session)
            .flatMap(clean)
    }

    static func clean(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        guard let limited = Summary.limited(t), limited.count >= 20 else { return nil }
        return limited
    }
}
