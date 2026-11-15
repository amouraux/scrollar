import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Asking a language model what a project is about, to suggest keywords to follow. Only ever because
/// the user asked, only with an excerpt they were shown (when it leaves the device), and never
/// automatically: the project may be a confidential proposal.
///
/// Two routes. Apple's on-device model, where the device has one: the text stays on the device and
/// never goes to Private Cloud Compute. Or a Claude or ChatGPT account the user set up in Tune, with
/// their own key: then the excerpt goes to that company, which is why the screen that asks says so.
enum ProjectAI {
    enum Route: Equatable {
        case onDevice
        case service(RemoteSummaryConfig)

        var name: String {
            switch self {
            case .onDevice: return "Apple's on-device model"
            case .service(let c): return c.displayName
            }
        }
    }

    enum Failure: LocalizedError {
        case declined, unavailable, failed(String)
        var errorDescription: String? {
            switch self {
            case .declined: return "The model gave nothing usable, or declined to read the text. The phrases counted in the text are below."
            case .unavailable: return "This device has no on-device language model."
            case .failed(let why): return why
            }
        }
    }

    static var onDeviceAvailable: Bool { Summarizer.isAvailable }

    /// What goes to the model: for a service, the excerpt shown beforehand and nothing else.
    static func excerpt(for route: Route, text: String) -> String {
        ProjectBrief.excerpt(text, limit: route == .onDevice ? ProjectBrief.onDeviceLimit : ProjectBrief.remoteLimit)
    }

    /// `excerpt` is what the user was shown for a service; the on-device model chooses its own, smaller one.
    static func ask(_ route: Route, excerpt: String, text: String) async throws -> [ProjectKeyword] {
        switch route {
        case .onDevice: return try await onDevice(text: text)
        case .service(let config):
            do {
                guard let answer = try await RemoteSummary.answer(config, system: ProjectBrief.instructions,
                                                                  user: ProjectBrief.prompt(excerpt)) else { throw Failure.declined }
                let words = ProjectBrief.keywords(from: answer, in: text)
                if words.isEmpty { throw Failure.declined }
                return words
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.failed("\(ErrorText.brief(error))")
            }
        }
    }

    /// A title for an interest, from Apple's on-device model only, or nil: no model on this device, a refusal,
    /// or an answer that is not a title. Never a service, even one set up: a title is not worth sending the text.
    static func title(for text: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let session = LanguageModelSession(model: .default, instructions: InterestTitle.instructions)
            guard let response = try? await session.respond(to: InterestTitle.prompt(text),
                                                            options: GenerationOptions(temperature: 0.3)) else { return nil }
            return InterestTitle.clean(response.content, text: text)
        }
        #endif
        return nil
    }

    /// Two questions to the on-device model. First it chooses from phrases found in the text, which a small
    /// model does well and which cannot bring in a phrase the text never uses. Then it writes its own list,
    /// as before, of which only the phrases the text does use are kept: that finds a term said once, which
    /// counting misses. The permissive guardrails, because Apple's default ones refuse much of medicine
    /// (depression, self-injury, anaesthesia) when a text is only being read; they apply to a plain-text
    /// answer only, which is why the choice is matched to the list here rather than constrained by a schema.
    private static func onDevice(text: String) async throws -> [ProjectKeyword] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { throw Failure.unavailable }
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let candidates = KeywordPick.candidates(counted: ProjectText.keywords(text, limit: 60),
                                                    nounPhrases: nounPhrases(in: text), text: text)
            var picked: [ProjectKeyword] = []
            if candidates.count >= 6 {
                for limit in [KeywordPick.excerptLimit, KeywordPick.excerptLimit / 2] {
                    let session = LanguageModelSession(model: model, instructions: KeywordPick.instructions)
                    let prompt = KeywordPick.prompt(excerpt: ProjectBrief.excerpt(text, limit: limit), candidates: candidates)
                    if let response = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.1)) {
                        picked = KeywordPick.matched(response.content, candidates: candidates)
                        if !picked.isEmpty { break }
                    }
                }
            }
            var written: [ProjectKeyword] = []
            // The window is small; if the text does not fit, try once with half of it.
            for limit in [ProjectBrief.onDeviceLimit, ProjectBrief.onDeviceLimit / 2] {
                let session = LanguageModelSession(model: model, instructions: ProjectBrief.instructions)
                let prompt = ProjectBrief.prompt(ProjectBrief.excerpt(text, limit: limit))
                if let response = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2)) {
                    written = ProjectBrief.keywords(from: response.content, in: text)
                    if !written.isEmpty { break }
                }
            }
            let words = KeywordPick.combine(picked: picked, written: written, text: text)
            if words.isEmpty { throw Failure.declined }
            return words
        }
        #endif
        throw Failure.unavailable
    }

    /// Runs of adjectives and nouns ending in a noun, two to four words long, with how often each occurs: the
    /// shape of a technical term ("conditioned pain modulation"), which counting word pairs cuts in two.
    static func nounPhrases(in text: String) -> [(phrase: String, count: Int)] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        var run: [(word: String, tag: NLTag)] = []
        func close() {
            while let last = run.last, last.tag != .noun { run.removeLast() }
            while let first = run.first, first.tag != .noun && first.tag != .adjective { run.removeFirst() }
            if (2...4).contains(run.count) {
                let words = run.map { $0.word.filter(\.isUppercase).count >= 2 ? $0.word : $0.word.lowercased() }
                let key = words.joined(separator: " ").lowercased()
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = words.joined(separator: " ") }
            }
            run = []
        }
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace]) { tag, range in
            let word = String(text[range])
            if let tag, tag == .noun || tag == .adjective, word.count > 1, word.first?.isLetter == true {
                run.append((word, tag))
            } else {
                close()
            }
            return true
        }
        close()
        return counts.map { (display[$0.key] ?? $0.key, $0.value) }
    }
}
