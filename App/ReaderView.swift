import SwiftUI
import PDFKit

/// The paper open beside the feed on a wide window: everything a post leaves out, in one place.
/// It shows whatever `AppModel.readerPaper` is; the feed column sets it by a tap.
struct ReaderPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let paper = model.readerPaper {
                PaperReader(paper: paper)
                    // A new paper starts at the top, not where the last one was scrolled to.
                    .id(paper.dedupeKey)
            } else {
                ContentUnavailableView {
                    Label("Choose a paper", systemImage: "doc.text")
                } description: {
                    Text("Its abstract, authors and the reason it is in your feed appear here.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct PaperReader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let paper: Paper
    private enum Mode: String, CaseIterable { case details = "Details", pdf = "PDF" }
    @State private var mode = Mode.details
    /// Owned here, not by the PDF view, so going to Details and back does not fetch the file again.
    @State private var pdf = PDFLoader()

    private var pdfLink: URL? { PDFLink.clean(paper.pdfURL).flatMap(URL.init(string:)) }

    private var authors: Reader.AuthorList { Reader.authors(of: paper) }

    var body: some View {
        VStack(spacing: 0) {
            if pdfLink != nil {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .padding(.vertical, 8)
            }
            if mode == .pdf, let link = pdfLink {
                PDFPane(loader: pdf, url: link)
            } else {
                details
            }
        }
        // The buttons stay in reach however long the abstract is.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                actions.padding(.horizontal, 24).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .background(.bar)
        }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Text(paper.title)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !authors.isEmpty { authorsSection }
                reasonsSection
                abstractSection
                aboutSection
                if let url = paper.link { linkSection(url) }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header

    /// The journal in its own colours, as on the post, with what kind of paper it is and when.
    private var header: some View {
        ZStack(alignment: .topLeading) {
            JournalBackdrop(paper: paper)
            VStack(alignment: .leading, spacing: 3) {
                Text(paper.journal ?? paper.topics.first ?? "Unpublished")
                    .font(.headline.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subline).font(.subheadline).opacity(0.9)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .padding(.trailing, 56)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var subline: String {
        var parts: [String] = []
        if paper.journal != nil, let topic = paper.topics.first { parts.append(topic) }
        parts.append(ageLabel(paper.date))
        if paper.kind != .research { parts.append(paper.kind.label) }
        return parts.joined(separator: " · ")
    }

    // MARK: Authors

    private var authorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Authors")
            ForEach(Array(authors.head.enumerated()), id: \.offset) { _, line in authorRow(line) }
            if authors.omitted > 0 {
                Text("and \(authors.omitted) more")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.leading, 40)
            }
            if let last = authors.tail { authorRow(last) }
        }
    }

    private func authorRow(_ line: Reader.AuthorLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            BylineBadge(initials: Byline.initials(line.name), hue: Byline.hue(for: line.name), size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(line.name).font(.subheadline.weight(.semibold))
                    switch line.role {
                    case .first where authors.head.count + (authors.tail == nil ? 0 : 1) > 1: roleTag("First")
                    case .last: roleTag("Last")
                    default: EmptyView()
                    }
                }
                if let place = line.institution {
                    Text(place).font(.footnote).foregroundStyle(.secondary)
                }
                if let h = line.hIndex {
                    Text("h-index \(h)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func roleTag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    // MARK: Why it is here

    @ViewBuilder private var reasonsSection: some View {
        let whys = Why.all(for: paper)
        let highlight = model.layout.highlights.first { $0.ranked.paper.dedupeKey == paper.dedupeKey }?.reason
        if !whys.isEmpty || highlight != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Why it is in your feed")
                if let highlight {
                    Label(highlight.prefix(1).uppercased() + highlight.dropFirst(), systemImage: "star.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                }
                ForEach(Array(whys.enumerated()), id: \.offset) { _, why in
                    Label(why.text, systemImage: why.symbol)
                        .font(.subheadline)
                        .foregroundStyle(why.isCitation ? Color.accentColor : Color.primary)
                }
            }
        }
    }

    // MARK: Abstract

    private var abstractSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Abstract")
            if let text = paper.abstract {
                Text(text)
                    .font(.body)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("No abstract available.").foregroundStyle(.tertiary)
            }
            if model.takeaway(for: paper)?.writtenByModel == true {
                Label("The sentences on the post were written on this device by Apple's language model. The abstract is the authors' own.",
                      systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: About the paper

    /// The journal and the figures the open data has for it, only where known.
    @ViewBuilder private var aboutSection: some View {
        let facts = aboutFacts
        if !facts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("About")
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    Label(fact.text, systemImage: fact.symbol).font(.footnote).foregroundStyle(.secondary)
                }
                if !paper.sourceNames.isEmpty {
                    Text("Found in " + paper.sourceNames.joined(separator: " and "))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var aboutFacts: [(text: String, symbol: String)] {
        var out: [(String, String)] = []
        if let impact = paper.journalImpact {
            out.append(("Journal impact " + String(format: "%.1f", impact) + " (OpenAlex two-year mean citedness)", "chart.bar"))
        }
        if paper.citedBy > 0 { out.append(("Cited by \(paper.citedBy)", "quote.bubble")) }
        if paper.isOpenAccess { out.append(("Open access", "lock.open")) }
        if !paper.topics.isEmpty { out.append((paper.topics.prefix(4).joined(separator: " · "), "tag")) }
        return out
    }

    private func linkSection(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Link")
            Link(destination: url) {
                Text(url.absoluteString).font(.footnote).multilineTextAlignment(.leading)
            }
            .simultaneousGesture(TapGesture().onEnded { model.markOpened(paper) })
            if let pdf = pdfLink {
                Link(destination: pdf) {
                    Label("Free PDF", systemImage: "doc.richtext").font(.footnote)
                }
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 0) {
            let saved = model.isSaved(paper)
            actionButton(saved ? "Saved" : "Save", saved ? "bookmark.fill" : "bookmark",
                         hint: "Saves it, and finds more like it") { model.toggleSaved(paper) }
            actionButton("Not for me", "hand.thumbsdown", hint: "Hides this paper for good") {
                withAnimation { model.hide(paper) }
            }
            if let url = paper.link {
                actionButton("Open", "arrow.up.right.square", hint: "Opens the paper in your browser") {
                    model.markOpened(paper)
                    openURL(url)
                }
                ShareLink(item: url, subject: Text(paper.title)) {
                    actionLabel("Share", "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actionButton(_ title: String, _ image: String, hint: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, image) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(hint)
    }

    private func actionLabel(_ title: String, _ image: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: image).font(.system(size: 18))
            Text(title).font(.caption).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}


/// Fetches a paper's PDF and holds it. A site that answers with a web page (a paywall, a cookie
/// notice, a "are you a robot" check) is not a PDF, and the pane says so instead of showing nothing.
@MainActor @Observable
final class PDFLoader {
    enum State { case idle, loading, ready(PDFDocument), failed(String) }
    private(set) var state = State.idle
    /// Files this large are left to the browser: they would be held in memory in full.
    private static let largest = 80_000_000

    func load(_ url: URL) async {
        switch state { case .idle, .failed: break; default: return }
        state = .loading
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/pdf,*/*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (file, response) = try await URLSession.shared.download(for: request)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.largest else { state = .failed("This PDF is too large to show here."); return }
            let data = try Data(contentsOf: file)
            guard data.prefix(5) == Data("%PDF-".utf8), let document = PDFDocument(data: data) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                state = .failed(status >= 400 ? "The site refused the download (error \(status))."
                                              : "The site sent a web page, not a PDF.")
                return
            }
            state = .ready(document)
        } catch {
            state = .failed("The PDF could not be loaded. Check the connection.")
        }
    }
}

private struct PDFPane: View {
    @Environment(\.openURL) private var openURL
    let loader: PDFLoader
    let url: URL

    var body: some View {
        Group {
            switch loader.state {
            case .idle, .loading:
                VStack(spacing: 10) { ProgressView(); Text("Loading the PDF…").font(.subheadline).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let document):
                PDFKitView(document: document)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not show the PDF", systemImage: "doc.badge.ellipsis")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await loader.load(url) } }
                    Button("Open in browser") { openURL(url) }
                }
            }
        }
        .task(id: url) { await loader.load(url) }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
