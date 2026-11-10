import SwiftUI

// Start again, all of it or by parts (Core/Reset.swift). Choose what to clear, confirm, and it is done; what was
// there is kept until the app closes, so the last reset can be undone. The backup is the way back for good.

struct ResetScreen: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: Set<ResetPart> = []
    @State private var asking = false
    @State private var everything = false
    @State private var creatingBackup = false

    var body: some View {
        let settings = model.settings
        Form {
            if let snap = model.resetSnapshot {
                Section {
                    Button { model.undoReset() } label: {
                        Label("Undo the reset of \(snap.at.formatted(date: .omitted, time: .shortened))", systemImage: "arrow.uturn.backward")
                    }
                } footer: {
                    Text("Puts back what it cleared (\(ResetPart.allCases.filter(snap.parts.contains).map { $0.title.lowercased() }.joined(separator: ", "))). It is kept until the app closes.")
                }
            }

            Section {
                ForEach(ResetPart.allCases) { part in row(part, settings) }
            } header: {
                Text("What to clear")
            } footer: {
                Text("Everything else stays as it is. Your OpenAlex, Zotero and summary keys, and the link to your sync file, are never touched here.")
            }

            Section {
                Button("Clear what is ticked (\(chosen.count))", role: .destructive) { everything = false; asking = true }
                    .disabled(chosen.isEmpty)
                Button("Clear everything", role: .destructive) { everything = true; asking = true }
            } footer: {
                Text("With syncing on, the other devices follow a reset of settings (follows, thumbs, the reading list, sliders). Recent searches and projects stay on each device. What you have read is merged between devices, so it can come back from one that still has it.")
            }

            Section {
                Button("Save a backup first…") { creatingBackup = true }
            }
        }
        .navigationTitle("Start again")
        .fileExporter(isPresented: $creatingBackup,
                      document: SyncFileDocument(data: creatingBackup ? model.backupData() : Data()),
                      contentType: .json, defaultFilename: Backup.filename(at: Date())) { _ in }
        .confirmationDialog(everything ? "Clear everything?" : "Clear what is ticked?", isPresented: $asking, titleVisibility: .visible) {
            Button(everything ? "Clear everything" : "Clear \(chosen.count) \(chosen.count == 1 ? "part" : "parts")", role: .destructive) {
                let parts = everything ? Set(ResetPart.allCases) : chosen
                model.reset(parts)
                chosen = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let parts = everything ? ResetPart.allCases : ResetPart.allCases.filter(chosen.contains)
            Text("This clears " + parts.map { $0.title.lowercased() }.joined(separator: ", ") + ". You can undo it until the app closes; a backup is the only way back after that.")
        }
    }

    private func row(_ part: ResetPart, _ s: FeedSettings) -> some View {
        let on = chosen.contains(part)
        return Button {
            if on { chosen.remove(part) } else { chosen.insert(part) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(part.title).foregroundStyle(.primary)
                    Text(part.clears).font(.caption).foregroundStyle(.secondary)
                    if let detail = detail(part, s) { Text(detail).font(.caption.weight(.medium)).foregroundStyle(.tint) }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// How much there is to clear, including what only the device knows.
    private func detail(_ part: ResetPart, _ s: FeedSettings) -> String? {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 0 ? "Nothing to clear" : "\(count) \(count == 1 ? one : many)" }
        switch part {
        case .searches: return n(model.searches.count, "search", "searches")
        case .projects: return n(model.projects.count, "project", "projects")
        case .history: return n(model.history.states.count, "paper seen or read", "papers seen or read")
        default: return part.detail(in: s)
        }
    }
}
