import Foundation
import NaturalLanguage

/// Apple's on-device sentence embeddings: free, offline, and nothing leaves the
/// phone. The model is trained on sentences, not paragraphs, so an abstract is
/// embedded sentence by sentence and the vectors averaged.
struct NLTextEmbedder: TextEmbedder {
    private let embedding: NLEmbedding
    private let maxSentences: Int

    /// nil when this device has no English sentence model.
    init?(language: NLLanguage = .english, maxSentences: Int = 4) {
        guard let e = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        embedding = e
        self.maxSentences = maxSentences
    }

    let modelID = "apple-sentence"

    func vector(for text: String) -> [Double]? {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var all: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            all.append(String(text[range]))
            return true
        }
        // Embedding is the slow part (about 60 ms a sentence), so use the title and
        // the last sentences: an abstract's conclusion says more about what the
        // paper found than its opening says about the field.
        let chosen = all.count <= maxSentences ? all : [all[0]] + all.suffix(maxSentences - 1)

        var sum: [Double] = []
        var used = 0
        for s in chosen {
            guard let v = embedding.vector(for: s) else { continue }
            if sum.isEmpty { sum = v } else { for i in 0..<min(sum.count, v.count) { sum[i] += v[i] } }
            used += 1
        }
        return used == 0 ? nil : Vectors.normalise(sum)
    }
}


/// Apple's contextual (BERT-style) text model, which needs neither Apple Intelligence nor a
/// region where it is offered: it is a downloadable language asset. Where a device has no sentence
/// model it stands in. Token vectors are averaged; the model reads up to 256 tokens, so a long
/// text keeps its beginning and its end, where an abstract says what it is about and what it found.
final class NLContextualTextEmbedder: TextEmbedder {
    let modelID = "apple-contextual"
    private let embedding: NLContextualEmbedding
    private let language: NLLanguage
    private let lock = NSLock()

    private init(_ embedding: NLContextualEmbedding, language: NLLanguage) {
        self.embedding = embedding
        self.language = language
    }

    /// nil when the model is not on this device and could not be fetched (no connection, the
    /// asset service said no). The first use downloads it once; after that it is on the device.
    static func make(language: NLLanguage = .english) async -> NLContextualTextEmbedder? {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        if !model.hasAvailableAssets {
            guard (try? await model.requestAssets()) == .available else { return nil }
        }
        guard (try? model.load()) != nil else { return nil }
        return NLContextualTextEmbedder(model, language: language)
    }

    static func excerpt(_ text: String, limit: Int = 1400) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit / 3)) + " " + String(text.suffix(limit * 2 / 3))
    }

    func vector(for text: String) -> [Double]? {
        let text = Self.excerpt(text)
        lock.lock(); defer { lock.unlock() }
        guard let result = try? embedding.embeddingResult(for: text, language: language) else { return nil }
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
            for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
            count += 1
            return true
        }
        return count == 0 ? nil : Vectors.normalise(sum)
    }
}

enum TextEmbedders {
    /// The best on-device model this device has: Apple's sentence model, else its contextual model,
    /// else none (and similarity is judged by word counts alone). None of them is Apple Intelligence.
    static func best() async -> TextEmbedder? {
        if let sentence = NLTextEmbedder() { return sentence }
        return await NLContextualTextEmbedder.make()
    }
}
