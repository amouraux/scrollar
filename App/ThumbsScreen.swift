import SwiftUI

// What the thumbs have taught the feed about each keyword, journal, researcher and topic, and how that is read.
// Each thumb is an event; a thing's pull is worked out from its events (Core/Evidence.swift): clicks fade, are read
// against what is typical for you, and a change of heart counts for more. Everything here can be changed, and a
// thing can be pinned to a level by hand, which wins over what was learned.

struct ThumbsScreen: View {
    @Environment(AppModel.self) private var appModel

    private static let halfLives: [(label: String, days: Double)] = [
        ("Never", 0), ("2 weeks", 14), ("1 month", 30), ("2 months", 60), ("3 months", 90), ("6 months", 180), ("12 months", 365),
    ]

    var body: some View {
        @Bindable var model = appModel
        let learned = Evidence.learn(model.settings.thumbEvents, model.settings.evidence, now: Date())
        Form {
            Section {
                if learned.isEmpty {
                    Text("Nothing yet. Press For me or Not for me on a post and choose what it is about: each choice is counted here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(learned, id: \.ref.key) { facet in row(facet) }
            } header: {
                Text("What your thumbs have taught")
            } footer: {
                Text("Each line is one keyword, journal, researcher or topic. ↑ and ↓ are the thumbs you gave it, the bar and the number are how much it raises or lowers a paper that carries it now, after fading. Swipe left to forget its thumbs. A pin sets it by hand and wins over what was learned.")
            }

            Section {
                Picker("A For me counts half as much after", selection: $model.settings.evidence.halfLifeUpDays) {
                    ForEach(Self.halfLives, id: \.days) { Text($0.label).tag($0.days) }
                }
                Picker("A Not for me counts half as much after", selection: $model.settings.evidence.halfLifeDownDays) {
                    ForEach(Self.halfLives, id: \.days) { Text($0.label).tag($0.days) }
                }
            } header: {
                Text("How they fade")
            } footer: {
                Text("A thing you stopped pushing down comes back by itself. Not for me fades faster than For me by default, so a topic can return to your feed.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("How strongly they pull")
                    Slider(value: $model.settings.evidence.strength, in: 0...1)
                    HStack {
                        Text("Not at all").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Fully").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("At most a thing raises a paper by 0.8 or lowers it by 0.6, whatever the number of thumbs, and thumbs never hide a topic. The first thumbs count most, the tenth hardly adds. What counts as a lot is read against how much you click: a user who clicks the same things all the time has each click count for less.")
            }

            Section {
                Stepper(value: $model.settings.evidence.promoteAfterDemote, in: 1...5, step: 0.5) {
                    LabeledContent("For me after Not for me counts", value: times(model.settings.evidence.promoteAfterDemote))
                }
                VStack(alignment: .leading) {
                    LabeledContent("…and forgives", value: percent(model.settings.evidence.forgiveDemotes) + " of the earlier Not for me")
                    Slider(value: $model.settings.evidence.forgiveDemotes, in: 0...1, step: 0.1)
                }
                Stepper(value: $model.settings.evidence.demoteAfterPromote, in: 1...5, step: 0.5) {
                    LabeledContent("Not for me after For me counts", value: times(model.settings.evidence.demoteAfterPromote))
                }
                VStack(alignment: .leading) {
                    LabeledContent("…and forgives", value: percent(model.settings.evidence.forgivePromotes) + " of the earlier For me")
                    Slider(value: $model.settings.evidence.forgivePromotes, in: 0...1, step: 0.1)
                }
                Button("Back to the usual numbers") { model.settings.evidence = EvidenceSettings() }
                    .disabled(model.settings.evidence == EvidenceSettings())
            } header: {
                Text("Change of heart")
            } footer: {
                Text("A thing is shown less once you push it down, so you have fewer chances to like it again. A For me on something you kept pushing down is therefore a rare, deliberate sign, and counts for more than the reverse.")
            }

            Section {
                NavigationLink { InterestsScreen() } label: { Label("Levels set by hand", systemImage: "slider.horizontal.3") }
                Button("Forget every thumb", role: .destructive) { model.settings.thumbEvents = [] }
                    .disabled(model.settings.thumbEvents.isEmpty)
            } footer: {
                Text("Forgetting thumbs leaves your reading list, For me and hidden papers as they are.")
            }
        }
        .navigationTitle("Your thumbs")
    }

    private func times(_ x: Double) -> String { String(format: x == x.rounded() ? "×%.0f" : "×%.1f", x) }
    private func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    private func row(_ f: LearnedFacet) -> some View {
        @Bindable var model = appModel
        let pinned = model.settings.override(f.ref)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(f.ref.name).font(.headline).lineLimit(2)
                Text("\(f.ref.kind.singular) · ↑\(f.ups) ↓\(f.downs) · last \(Date(timeIntervalSince1970: f.lastAt).formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
                PullBar(value: pinned == nil ? f.pull * min(max(model.settings.evidence.strength, 0), 1) : 0)
                    .frame(height: 6)
                    .opacity(pinned == nil ? 1 : 0.35)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(pinned == nil ? String(format: "%+.2f", f.bonus) : "pinned")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(pinned != nil ? Color.secondary : (f.bonus >= 0 ? Color.accentColor : Color.orange))
                Menu {
                    Button { model.settings.clearLevel(f.ref) } label: {
                        Label("Automatic (from your thumbs)", systemImage: pinned == nil ? "checkmark" : "")
                    }
                    Divider()
                    ForEach(f.ref.kind.levels.reversed(), id: \.self) { level in
                        Button { model.settings.setLevel(level, for: f.ref) } label: {
                            Label(level.title, systemImage: pinned == level ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label(pinned.map { "Pinned: \($0.title)" } ?? "Pin", systemImage: "pin")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions { Button("Forget", role: .destructive) { model.settings.forgetThumbs(f.ref) } }
    }
}

/// A bar from -1 to +1 with its middle at the centre: orange to the left, the accent colour to the right.
private struct PullBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let v = min(max(value, -1), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(v >= 0 ? Color.accentColor : Color.orange)
                    .frame(width: max(abs(v) * half, v == 0 ? 0 : 3))
                    .offset(x: v >= 0 ? half : half + v * half)
                Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1).offset(x: half)
            }
        }
        .accessibilityHidden(true)
    }
}
