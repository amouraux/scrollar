import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// RIS has no system type; the extension is what Zotero, EndNote and the rest recognise it by.
    static let ris = UTType(filenameExtension: "ris", conformingTo: .plainText) ?? .plainText
}

/// A `.ris` file made at the moment it is shared, not when the button is drawn: a list of
/// hundreds of saved papers is not turned into text on every redraw.
struct ReferenceFile: Transferable {
    let name: String
    let make: @Sendable () -> [RIS.Reference]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .ris) { file in
            // A folder of its own, so two exports with the same name never overwrite each other.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(file.name)
            try Data(RIS.document(file.make()).utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// Share on a post and in the pane: the link, the reference as a file that a reference manager
/// opens (Zotero, EndNote, Mendeley and the others all read RIS), or, with a Zotero account
/// connected in Tune, straight into the Zotero library.
struct ShareMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    let paper: Paper
    @ViewBuilder var label: () -> Label

    var body: some View {
        let reference = RIS.reference(paper)
        let name = RIS.fileName(for: reference)
        Menu {
            if let url = paper.link {
                ShareLink(item: url, subject: Text(paper.title)) {
                    SwiftUI.Label("Share link", systemImage: "link")
                }
            }
            if model.zotero != nil {
                Button { Task { await model.saveToZotero(paper) } } label: {
                    SwiftUI.Label("Save to Zotero", systemImage: "tray.and.arrow.down")
                }
            }
            ShareLink(item: ReferenceFile(name: name, make: { [reference] }),
                      preview: SharePreview(name, image: Image(systemName: "books.vertical"))) {
                SwiftUI.Label("Share reference (.ris)", systemImage: "books.vertical")
            }
        } label: {
            label()
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Share")
        .accessibilityHint("Shares the link, or the reference for a reference manager")
    }
}
