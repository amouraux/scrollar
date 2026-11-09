import Foundation

// Takeaways written by a language model the user has an account with, for a device that has no
// on-device one (Apple Intelligence is not offered everywhere). Pure request building and answer
// reading, so what is sent and what is kept can be tested; the call is at the bottom, over a session
// the tests replace.

enum SummaryProvider: String, Codable, CaseIterable {
    case anthropic, openai
    /// Any service that speaks OpenAI's chat completions: Mistral, Gemini's compatible endpoint,
    /// OpenRouter, DeepSeek and others, or a model running on the user's own Mac (Ollama, LM Studio).
    case other

    var name: String {
        switch self {
        case .anthropic: return "Claude"
        case .openai: return "ChatGPT"
        case .other: return "Other model"
        }
    }

    /// How it is listed when choosing.
    var pickerTitle: String { self == .other ? "Other (OpenAI-compatible)" : name }

    /// Who runs it, which is who receives what is sent. For another service it is its address, in `RemoteSummaryConfig`.
    var company: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .other: return "the service you set up"
        }
    }

    /// Anthropic's most capable current model is the default; the model is the user's to change
    /// (a smaller one costs far less per summary, and a summary is a small task). Another service has
    /// none: only the user knows what it offers.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-5-5"
        case .openai: return "gpt-4o-mini"
        case .other: return ""
        }
    }
}

/// What the user set up in Tune. The whole value, key included, lives in the Keychain.
struct RemoteSummaryConfig: Codable, Equatable {
    var provider: SummaryProvider
    var key: String
    var model: String
    /// The address of another service (provider `.other`): as typed, without the path of the request.
    var endpoint: String = ""

    init(provider: SummaryProvider, key: String, model: String, endpoint: String = "") {
        self.provider = provider
        self.key = key
        self.model = model
        self.endpoint = endpoint
    }

    enum CodingKeys: String, CodingKey { case provider, key, model, endpoint }

    /// Tolerant like every stored type: an account set up before another service could be named has no address.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(SummaryProvider.self, forKey: .provider)
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? ""
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        endpoint = (try? c.decodeIfPresent(String.self, forKey: .endpoint)) ?? ""
    }

    var modelOrDefault: String {
        let m = model.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? provider.defaultModel : m
    }

    /// Where a request to another service goes; nil if the address will not do (see `RemoteSummary.endpoint`).
    var endpointURL: URL? { provider == .other ? RemoteSummary.endpoint(endpoint) : nil }

    /// The host that receives what is sent, as it must be said to the user.
    var receiver: String { provider == .other ? (endpointURL?.host ?? "an address you typed") : provider.company }

    /// What to call it on a screen.
    var displayName: String { provider == .other ? "your model at \(receiver)" : provider.name }
}

enum RemoteSummaryError: Error, CustomStringConvertible {
    case refused
    case slowDown
    case server(Int)
    case unreadable
    case badAddress

    var description: String {
        switch self {
        case .refused: return "The key was refused. Check it, the model name, and that the account has credit."
        case .slowDown: return "The service asked to slow down."
        case .server(let code): return "The service answered with an error (\(code))."
        case .unreadable: return "The service's answer could not be read."
        case .badAddress: return "That address will not do. It must start with https://, or with http:// only for a model on this device or your own network, and give the model name."
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

    /// Where a request to another service goes, from the address the user typed: https, or http only for a
    /// model on this device or the user's own network (nothing else is sent in the clear), with the path
    /// of a chat request added unless it is there. nil if the address will not do.
    static func endpoint(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard var parts = URLComponents(string: t), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        guard scheme == "https" || (scheme == "http" && isLocal(host)) else { return nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        parts.path = path
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// This device or a private network: the only places a model may be reached without encryption.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
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
        case .other:
            r = URLRequest(url: config.endpointURL ?? URL(string: "https://invalid.invalid/")!)
            // A model on the user's own machine needs no key.
            if !config.key.isEmpty { r.setValue("Bearer " + config.key, forHTTPHeaderField: "Authorization") }
            // `max_tokens` is the name every compatible service knows; OpenAI's newer one is not universal.
            body = ["model": model, "max_tokens": 2000,
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
        case .openai, .other:
            let message = ((o["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
            if message?["refusal"] is String { return nil }
            return (message?["content"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// The text of the service's answer to one question, nil when it declined; throws when the call
    /// failed, so the user can be told why.
    static func answer(_ config: RemoteSummaryConfig, system: String, user: String,
                       session: URLSession = .shared) async throws -> String? {
        if config.provider == .other, config.endpointURL == nil || config.modelOrDefault.isEmpty { throw RemoteSummaryError.badAddress }
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
