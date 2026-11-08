import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// How an attempt to write a takeaway ended.
enum SummaryOutcome {
    case text(String)
    /// The model chose not to (it may refuse medical text), or what it wrote was unusable.
    case declined
    /// The call failed: a refused key, no connection. The reason is for the user.
    case failed(String)
    /// Nothing here can write one.
    case unavailable
}

/// Writes the one-or-two-sentence takeaway of a paper: with Apple's on-device language model where the
/// device has one (nothing leaves the phone, and never Private Cloud Compute), else, if the user set one
/// up in Tune, with a Claude or ChatGPT account of their own. Apple Intelligence is not offered
/// everywhere, so the second is how a device without it gets the same line.
///
/// One paper at a time on the device, a few at a time over the network. A feed has hundreds of
/// papers and a card that scrolls away before its turn should cost nothing.
actor Summarizer {
    static let shared = Summarizer()

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// A network call costs money, so a launch writes at most this many: a feed scrolled through for
    /// hours is a bill, and a bug that asked in a loop must not be able to run one up.
    static let remoteLimit = 200
    private static let remoteParallel = 3

    private var remote: RemoteSummaryConfig?
    private(set) var remoteCalls = 0
    private var remoteActive = 0
    private var remoteWaiting: [CheckedContinuation<Void, Never>] = []

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func configure(remote: RemoteSummaryConfig?) { self.remote = remote }

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

    private func enterRemote() async {
        if remoteActive >= Self.remoteParallel {
            await withCheckedContinuation { remoteWaiting.append($0) }
        } else {
            remoteActive += 1
        }
    }

    private func leaveRemote() {
        if remoteWaiting.isEmpty { remoteActive -= 1 } else { remoteWaiting.removeFirst().resume() }
    }

    func takeaway(title: String, abstract: String) async -> SummaryOutcome {
        if Self.isAvailable { return await onDevice(title: title, abstract: abstract) }
        guard let remote else { return .unavailable }
        guard remoteCalls < Self.remoteLimit else {
            return .failed("The limit of \(Self.remoteLimit) summaries written this way per launch is reached. The rest are chosen from the abstracts.")
        }
        await enterRemote()
        defer { leaveRemote() }
        if Task.isCancelled { return .declined }
        remoteCalls += 1
        do {
            return try await RemoteSummary.takeaway(remote, title: title, abstract: abstract).map(SummaryOutcome.text) ?? .declined
        } catch {
            return .failed("\(error)")
        }
    }

    private func onDevice(title: String, abstract: String) async -> SummaryOutcome {
        await enter()
        defer { leave() }
        if Task.isCancelled { return .declined }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(model: .default, instructions: RemoteSummary.instructions)
            let prompt = RemoteSummary.prompt(title: title, abstract: abstract)
            do {
                let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2))
                return RemoteSummary.clean(response.content).map(SummaryOutcome.text) ?? .declined
            } catch {
                return .declined
            }
        }
        #endif
        return .unavailable
    }
}
