import Foundation

/// A picture for every card, made from the paper and not fetched: it needs no
/// network, works offline, and raises no question about whose figure it is. The
/// same topic always gets the same colours, so the feed can be scanned by eye.
struct CoverSpec: Equatable {
    /// 0...1
    var hueA: Double
    var hueB: Double
    /// An SF Symbol name.
    var symbol: String
}

enum Cover {
    static func spec(for paper: Paper) -> CoverSpec {
        // Colour follows the first topic, so papers on one subject look related.
        let key = (paper.topics.first ?? paper.journal ?? paper.title).lowercased()
        let h = CachingEmbedder.hash(key)
        let a = Double(h % 360) / 360
        let shift = 0.06 + Double((h >> 20) % 14) / 100
        let b = (a + shift).truncatingRemainder(dividingBy: 1)
        return CoverSpec(hueA: a, hueB: b, symbol: symbol(for: paper))
    }

    // First match wins, so the more specific words come first.
    private static let symbols: [(words: [String], symbol: String)] = [
        (["ion channel", "receptor", "molecul", "protein", "enzyme"], "atom"),
        (["tactile", "touch", "somatosens", "haptic"], "hand.point.up.left"),
        (["pain", "noci", "analges"], "waveform.path.ecg"),
        (["brain", "neur", "cortex", "cognit", "eeg"], "brain.head.profile"),
        (["cancer", "tumor", "tumour", "oncolog"], "cross.case"),
        (["drug", "pharmac", "therap", "treatment"], "pills"),
        (["gene", "genom", "rna", "dna"], "testtube.2"),
        (["vision", "visual", "retina"], "eye"),
        (["auditory", "hearing", "sound"], "ear"),
        (["heart", "cardi"], "heart"),
        (["machine learning", "deep learning", "algorithm", "model"], "cpu"),
    ]

    static func symbol(for paper: Paper) -> String {
        let text = (paper.topics + [paper.title]).joined(separator: " ").lowercased()
        for entry in symbols where entry.words.contains(where: text.contains) { return entry.symbol }
        return "doc.text.magnifyingglass"
    }
}
