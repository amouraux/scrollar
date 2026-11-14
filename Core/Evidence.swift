import Foundation

// What the user's thumbs teach the feed about a keyword, journal, researcher or topic. A thumb used to move a
// level by one step and forget when and how often. Now each thumb is kept as an event, and a thing's pull is
// worked out from all its events:
//
//  - each click fades: it counts half as much after a while (promotes slower than demotes, so a topic that was
//    pushed down comes back by itself);
//  - the total is read against what is typical for this user (the middle one of the things they have clicked),
//    separately for promotes and demotes, so someone who demotes far more than they promote is not skewed;
//  - a saturating curve turns that into a pull between -1 and +1: the first clicks matter, the tenth hardly adds;
//  - a click that goes against the thing's current direction is a change of heart: it counts for more, and some of
//    the older clicks it contradicts are forgiven. Promoting what was long demoted counts for more than the
//    reverse, because a demoted thing is shown less and so has fewer chances to be clicked at all.
//
// A thing the user pinned to a level by hand is left to that level. Pure and tested; the screens are elsewhere.

/// How the thumbs are read. Every number is shown in Tune and can be changed there.
struct EvidenceSettings: Codable, Equatable {
    /// Days for a promote to count half as much; 0 means never.
    var halfLifeUpDays = 90.0
    /// Days for a demote to count half as much; 0 means never.
    var halfLifeDownDays = 60.0
    /// 0 to 1: how much of the pull is used. 0 switches learning from thumbs off.
    var strength = 1.0
    /// A promote after demotes counts this many times.
    var promoteAfterDemote = 2.0
    /// And this share of the older demotes it contradicts is forgiven (0 to 1).
    var forgiveDemotes = 0.6
    /// A demote after promotes counts this many times.
    var demoteAfterPromote = 1.5
    /// And this share of the older promotes it contradicts is forgiven.
    var forgivePromotes = 0.3

    init() {}

    // Hand-written so that a file with only some of the keys, or an older one, still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EvidenceSettings()
        halfLifeUpDays = (try? c.decodeIfPresent(Double.self, forKey: .halfLifeUpDays)) ?? d.halfLifeUpDays
        halfLifeDownDays = (try? c.decodeIfPresent(Double.self, forKey: .halfLifeDownDays)) ?? d.halfLifeDownDays
        strength = (try? c.decodeIfPresent(Double.self, forKey: .strength)) ?? d.strength
        promoteAfterDemote = (try? c.decodeIfPresent(Double.self, forKey: .promoteAfterDemote)) ?? d.promoteAfterDemote
        forgiveDemotes = (try? c.decodeIfPresent(Double.self, forKey: .forgiveDemotes)) ?? d.forgiveDemotes
        demoteAfterPromote = (try? c.decodeIfPresent(Double.self, forKey: .demoteAfterPromote)) ?? d.demoteAfterPromote
        forgivePromotes = (try? c.decodeIfPresent(Double.self, forKey: .forgivePromotes)) ?? d.forgivePromotes
    }
}

/// One thumb on one thing.
struct ThumbEvent: Codable, Hashable {
    var kind: FacetKind
    var id: String
    var name: String
    var up: Bool
    /// Seconds since 1970.
    var at: Double

    init(_ ref: FacetRef, up: Bool, at: Date) {
        kind = ref.kind; id = ref.id; name = ref.name; self.up = up; self.at = at.timeIntervalSince1970
    }

    var ref: FacetRef { FacetRef(kind: kind, id: id, name: name) }
    /// What identifies the event, for sync: the thing, the moment and the direction.
    var key: String { ref.key + "|" + String(Int(at * 1000)) + (up ? "u" : "d") }
}

/// What the events add up to for one thing.
struct LearnedFacet: Equatable {
    var ref: FacetRef
    /// Raw clicks, without fading.
    var ups: Int
    var downs: Int
    var lastAt: Double
    /// Faded, change-of-heart-adjusted totals.
    var promoteWeight: Double
    var demoteWeight: Double
    /// -1 to +1 after the normalisation and the curve, before the overall strength.
    var pull: Double
    /// Added to the score of a paper that carries the thing.
    var bonus: Double
}

enum Evidence {
    /// The most a thing can add or take away: the same as Higher and Lower.
    static let maxUp = 0.8
    static let maxDown = 0.6
    /// "Typical" is never taken as less than this, so one click early on still counts for something, nor more
    /// than `typicalCeiling`, so a user who clicks hundreds of times is not left with every pull diluted.
    static let typicalFloor = 1.5
    static let typicalCeiling = 6.0
    /// A thing pulled up this far is searched for, as raising it to Higher used to do.
    static let fetchBonus = 0.5
    /// Events that count for less than this are dropped, and no more than this many are kept.
    static let faded = 0.03
    static let keepAtMost = 3000

    private static let day = 86_400.0

    /// How much a click still counts after `age` seconds, against a half-life in days (0: never fades).
    static func fade(_ age: Double, halfLifeDays: Double) -> Double {
        guard halfLifeDays > 0 else { return 1 }
        return pow(0.5, max(age, 0) / (halfLifeDays * day))
    }

    private static func halfLife(_ up: Bool, _ cfg: EvidenceSettings) -> Double { up ? cfg.halfLifeUpDays : cfg.halfLifeDownDays }

    /// What the events of every thing add up to, the strongest pull first.
    static func learn(_ events: [ThumbEvent], _ cfg: EvidenceSettings, now: Date) -> [LearnedFacet] {
        let t = now.timeIntervalSince1970
        var groups: [String: [ThumbEvent]] = [:]
        for e in events { groups[e.ref.key, default: []].append(e) }

        struct Partial { var ref: FacetRef; var ups = 0; var downs = 0; var last = 0.0; var u = 0.0; var d = 0.0 }
        var parts: [Partial] = []
        for list in groups.values {
            let sorted = list.sorted { $0.at != $1.at ? $0.at < $1.at : ($0.up ? 1 : 0) < ($1.up ? 1 : 0) }
            // How much each click counts, after the change-of-heart rule has been applied in the order they came.
            var factor = Array(repeating: 1.0, count: sorted.count)
            for i in sorted.indices {
                let e = sorted[i]
                // What the earlier clicks added up to at the moment of this one.
                var before = 0.0
                for j in 0..<i {
                    let age = e.at - sorted[j].at
                    before += (sorted[j].up ? 1 : -1) * factor[j] * fade(age, halfLifeDays: halfLife(sorted[j].up, cfg))
                }
                guard before != 0, (before > 0) != e.up else { continue }
                // Against the direction so far: a change of heart.
                let forgive = e.up ? cfg.forgiveDemotes : cfg.forgivePromotes
                for j in 0..<i where sorted[j].up != e.up { factor[j] *= (1 - min(max(forgive, 0), 1)) }
                factor[i] = max(e.up ? cfg.promoteAfterDemote : cfg.demoteAfterPromote, 0)
            }
            var p = Partial(ref: sorted[sorted.count - 1].ref)
            for (e, f) in zip(sorted, factor) {
                let w = f * fade(t - e.at, halfLifeDays: halfLife(e.up, cfg))
                if e.up { p.ups += 1; p.u += w } else { p.downs += 1; p.d += w }
                p.last = max(p.last, e.at)
            }
            parts.append(p)
        }

        func typical(_ values: [Double]) -> Double {
            let v = values.filter { $0 > 0 }.sorted()
            guard !v.isEmpty else { return typicalFloor }
            let median = v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
            return min(max(median, typicalFloor), typicalCeiling)
        }
        let tu = typical(parts.map(\.u)), td = typical(parts.map(\.d))
        let strength = min(max(cfg.strength, 0), 1)

        return parts.map { p in
            let pull = tanh(p.u / tu - p.d / td)
            let scaled = pull * strength
            return LearnedFacet(ref: p.ref, ups: p.ups, downs: p.downs, lastAt: p.last, promoteWeight: p.u, demoteWeight: p.d,
                                pull: pull, bonus: scaled > 0 ? scaled * maxUp : scaled * maxDown)
        }
        .sorted { abs($0.bonus) != abs($1.bonus) ? abs($0.bonus) > abs($1.bonus) : $0.ref.name < $1.ref.name }
    }

    /// What the thumbs add for the things that count: those the user has not pinned by hand and that are not
    /// muted. Computed once per ranking, then matched against each paper.
    static func active(_ s: FeedSettings, now: Date) -> [(entry: LevelEntry, bonus: Double)] {
        guard !s.thumbEvents.isEmpty, s.evidence.strength > 0 else { return [] }
        return learn(s.thumbEvents, s.evidence, now: now).compactMap { f in
            guard abs(f.bonus) >= 0.005, s.override(f.ref) == nil, s.defaultLevel(f.ref) != .hide else { return nil }
            return (LevelEntry(kind: f.ref.kind, id: f.ref.id, name: f.ref.name, level: .normal), f.bonus)
        }
    }

    /// What the thumbs have pulled up far enough to be searched for, and the lists do not already search for. An
    /// institution known only by name cannot be asked for, so it only ranks. One rule for the seeds and for
    /// deciding whether a refresh must fetch everything again.
    static func fetched(_ s: FeedSettings, now: Date) -> [LevelEntry] {
        active(s, now: now).filter { entry, bonus in
            bonus >= fetchBonus && !s.defaultLevel(entry.ref).fetches
                && !(entry.kind == .institution && SourceRouting.isNamed(entry.id))
        }.map(\.entry)
    }

    /// What the thumbs add for one thing now (0 where it is pinned or has no clicks).
    static func bonus(_ ref: FacetRef, _ s: FeedSettings, now: Date) -> Double {
        active(s, now: now).first { $0.entry.key == ref.key }?.bonus ?? 0
    }

    /// The events with this one added: dropped if already there, and with what has faded to nothing, or beyond the
    /// limit, let go.
    static func adding(_ event: ThumbEvent, to events: [ThumbEvent], _ cfg: EvidenceSettings, now: Date) -> [ThumbEvent] {
        var all = events
        if !all.contains(where: { $0.key == event.key }) { all.append(event) }
        let t = now.timeIntervalSince1970
        all = all.filter { fade(t - $0.at, halfLifeDays: halfLife($0.up, cfg)) >= faded }
        if all.count > keepAtMost { all = Array(all.sorted { $0.at > $1.at }.prefix(keepAtMost)) }
        return all.sorted { $0.at < $1.at }
    }

    /// One line that says what a thumb did, for the toast.
    static func summary(_ ref: FacetRef, before: Double, after: Double, pinned: Level?) -> String {
        func f(_ x: Double) -> String { String(format: "%+.1f", x) }
        if let pinned { return "“\(ref.name)” is pinned at \(pinned.title), so the thumb is noted but changes nothing." }
        return "“\(ref.name)” \(f(before)) → \(f(after))"
    }
}

extension FeedSettings {
    /// Forget every thumb given to a thing.
    mutating func forgetThumbs(_ ref: FacetRef) { thumbEvents.removeAll { $0.ref.key == ref.key } }

    /// A thumb on a thing, recorded as an event.
    mutating func recordThumb(_ ref: FacetRef, up: Bool, at now: Date = Date()) {
        thumbEvents = Evidence.adding(ThumbEvent(ref, up: up, at: now), to: thumbEvents, evidence, now: now)
    }
}
