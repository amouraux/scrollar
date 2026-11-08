import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writes the one-or-two-sentence takeaway of a paper with Apple's on-device
/// language model, where the device has one. Nothing leaves the phone: this uses
/// the on-device model only, never Private Cloud Compute.
///
/// One paper at a time. The model is a shared resource, a feed has hundreds of
/// papers, and a card that scrolls away before its turn should cost nothing.
actor Summarizer {
    static let shared = Summarizer()

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func enter() async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
    }

    private func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    /// nil when there is no model, the caller was cancelled while waiting, or the
    /// model declined (it may refuse medical text); the caller then keeps the
    /// sentences chosen from the abstract.
    func takeaway(title: String, abstract: String) async -> String? {
        guard Self.isAvailable else { return nil }
        await enter()
        defer { leave() }
        if Task.isCancelled { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(model: .default, instructions: Self.instructions)
            let prompt = "Title: \(title)\n\nAbstract: \(String(abstract.prefix(3000)))"
            do {
                let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
                return Self.clean(response.content)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    private static let instructions = """
        You write the takeaway of a research paper for a scientist scrolling a feed. \
        In one or two sentences, at most 45 words, say what the study found or shows, \
        in plain and specific terms. Use only what the abstract states: add no background, \
        no opinion, and no number or claim that is not in it. If the abstract reports no \
        result, say in one sentence what the paper does. Reply with those sentences only, as one paragraph.
        """

    static func clean(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        guard let limited = Summary.limited(t), limited.count >= 20 else { return nil }
        return limited
    }
}
