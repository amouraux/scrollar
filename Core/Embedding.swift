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
