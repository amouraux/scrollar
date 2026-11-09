import SwiftUI
import UIKit
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// RIS has no system type; the extension is what Zotero, EndNote and the rest recognise it by.
    static let ris = UTType(filenameExtension: "ris", conformingTo: .plainText) ?? .plainText
    /// EndNote's own import format, which its apps open directly.
    static let enw = UTType(filenameExtension: "enw", conformingTo: .plainText) ?? .plainText
}

/// A reference file made at the moment it is shared, not when the button is drawn: a list of
/// hundreds of saved papers is not turned into text on every redraw.
struct ReferenceFile: Transferable {
    enum Format { case ris, enw }
    let name: String
    var format = Format.ris
    let make: @Sendable () -> [RIS.Reference]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .ris) { file in try file.write() }
    }

    func write() throws -> SentTransferredFile {
        // A folder of its own, so two exports with the same name never overwrite each other.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let text = format == .enw ? EndNote.document(make()) : RIS.document(make())
        try Data(text.utf8).write(to: url, options: .atomic)
        return SentTransferredFile(url)
    }
}

/// An EndNote import file. Its own type, so the share sheet offers it as `.enw` and not as RIS.
struct EndNoteFile: Transferable {
    let file: ReferenceFile
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .enw) { try $0.file.write() }
    }
}

/// A PDF kept by the cache, handed on under a readable name.
struct PDFFile: Transferable {
    let cached: URL
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { file in
            guard let copy = PDFCache.namedCopy(file.cached, as: file.name) else { throw CocoaError(.fileWriteUnknown) }
            return SentTransferredFile(copy)
        }
    }
}

/// Share on a post and in the pane. A reference manager is reached the way it can be:
/// - **Zotero**, once an account is connected in Tune, straight into the library (with the PDF and
///   in the collection chosen there). Without one, Zotero's own app takes the link or the PDF.
/// - **EndNote** opens an `.enw` file with a tap or a double-click; it has no way in from outside.
/// - **Mendeley and the rest** read a `.ris` file and a PDF (Mendeley's programming interface needs
///   an app registered with Elsevier, which is not something to ask of a reader).
struct ShareMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    let paper: Paper
    @ViewBuilder var label: () -> Label

    var body: some View {
        let reference = RIS.reference(paper)
        let ris = RIS.fileName(for: reference)
        let enw = EndNote.fileName(for: reference)
        let pdf = PDFCache.lookup(paper.dedupeKey)
        let hasPDFLink = paper.pdfLink != nil
        Menu {
            if let url = paper.link {
                ShareLink(item: url, subject: Text(paper.title)) {
                    SwiftUI.Label("Share link", systemImage: "link")
                }
            }
            Section("Send to a reference manager") {
                if let account = model.zotero {
                    Button { Task { await model.addToZotero(paper) } } label: {
                        SwiftUI.Label(account.canWrite ? "Add to Zotero" : "Add to Zotero (the key is read-only)",
                                      systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!account.canWrite)
                }
                ShareLink(item: EndNoteFile(file: ReferenceFile(name: enw, format: .enw, make: { [reference] })),
                          preview: SharePreview(enw, image: Image(systemName: "books.vertical"))) {
                    SwiftUI.Label("EndNote (.enw)", systemImage: "books.vertical")
                }
                ShareLink(item: ReferenceFile(name: ris, make: { [reference] }),
                          preview: SharePreview(ris, image: Image(systemName: "books.vertical"))) {
                    SwiftUI.Label("Mendeley, Zotero and others (.ris)", systemImage: "books.vertical")
                }
                Button { UIPasteboard.general.string = RIS.document([reference]); model.show("Reference copied") } label: {
                    SwiftUI.Label("Copy the reference as text", systemImage: "doc.on.clipboard")
                }
                if pdf != nil || hasPDFLink {
                    let name = ris.replacingOccurrences(of: ".ris", with: ".pdf")
                    if let pdf {
                        ShareLink(item: PDFFile(cached: pdf, name: name),
                                  preview: SharePreview(name, image: Image(systemName: "doc.richtext"))) {
                            SwiftUI.Label("Share the PDF", systemImage: "doc.richtext")
                        }
                    }
                    Button { Task { await model.copyPDF(paper) } } label: {
                        SwiftUI.Label("Copy the PDF", systemImage: "doc.on.doc")
                    }
                    if let folder = WatchedFolder.url {
                        Button { Task { await model.dropPDF(paper) } } label: {
                            SwiftUI.Label("Put the PDF in “\(folder.lastPathComponent)”", systemImage: "folder.badge.plus")
                        }
                    }
                }
            }
        } label: {
            label()
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Share")
        .accessibilityHint("Shares the link, or the reference for a reference manager")
    }
}

extension AppModel {
    /// The paper's PDF as a file: the kept copy, or a direct download made now. Says so when there is none.
    private func pdfFile(for p: Paper) async -> URL? {
        guard let link = p.pdfLink.flatMap(URL.init(string:)) else {
            if let kept = PDFCache.lookup(p.dedupeKey) { return kept }
            show("No free PDF is known for this paper.")
            return nil
        }
        if PDFCache.lookup(p.dedupeKey) == nil { show("Fetching the PDF…") }
        let stem = String(RIS.fileName(for: RIS.reference(p)).dropLast(4))
        guard let file = await PDFCache.file(for: p.dedupeKey, url: link, referer: p.link, stem: stem) else {
            show("The publisher would not hand over the PDF directly. Open the PDF tab, which can still show it, or open the paper in the browser.")
            return nil
        }
        return file
    }

    private func pdfName(_ p: Paper) -> String { RIS.fileName(for: RIS.reference(p)).replacingOccurrences(of: ".ris", with: ".pdf") }

    /// On the clipboard as a file under a readable name, to paste into a folder or an app that takes files.
    func copyPDF(_ p: Paper) async {
        guard let file = await pdfFile(for: p), let named = PDFCache.namedCopy(file, as: pdfName(p)),
              let provider = NSItemProvider(contentsOf: named) else { return }
        UIPasteboard.general.setItemProviders([provider], localOnly: false, expirationDate: Date().addingTimeInterval(3600))
        show("PDF copied")
    }

    /// Into the folder a reference manager watches, for it to import.
    func dropPDF(_ p: Paper) async {
        guard let file = await pdfFile(for: p) else { return }
        let name = pdfName(p)
        let result = await Task.detached { WatchedFolder.drop(file, name: name) }.value
        switch result {
        case .dropped(let folder): show("Put in “\(folder)”. The reference manager imports it when it next looks.")
        case .alreadyThere(let folder): show("Already in “\(folder)”.")
        case .noFolder: show("Choose the folder in Tune first.")
        case .failed: show("The PDF could not be written to that folder.")
        }
    }
}
