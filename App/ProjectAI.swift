import Foundation
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

    private static func onDevice(text: String) async throws -> [ProjectKeyword] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { throw Failure.unavailable }
            // The window is small; if the text does not fit, try once with half of it.
            for limit in [ProjectBrief.onDeviceLimit, ProjectBrief.onDeviceLimit / 2] {
                let session = LanguageModelSession(model: .default, instructions: ProjectBrief.instructions)
                let prompt = ProjectBrief.prompt(ProjectBrief.excerpt(text, limit: limit))
                if let response = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2)) {
                    let words = ProjectBrief.keywords(from: response.content, in: text)
                    if !words.isEmpty { return words }
                }
            }
            throw Failure.declined
        }
        #endif
        throw Failure.unavailable
    }
}
