import Foundation

// The parser and the merge are pure; the network half is PubMedClient.swift.

struct PubMedRecord: Equatable {
    var pmid: String
    var abstract: String?
    var publicationTypes: [String]
}

enum PubMedParser {
    /// Parse an EFetch `retmode=xml` response.
    static func parse(_ data: Data) -> [PubMedRecord] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.records
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var records: [PubMedRecord] = []

        private var path: [String] = []
        private var current: PubMedRecord?
        private var sections: [String] = []
        private var label: String?
        private var buffer: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "PubmedArticle":
                current = PubMedRecord(pmid: "", abstract: nil, publicationTypes: [])
                sections = []
            case "PMID":
                // The article's own PMID is the one directly under MedlineCitation;
                // the others belong to comments, corrections and references.
                if path.last == "MedlineCitation", current?.pmid.isEmpty == true { buffer = "" }
            case "AbstractText":
                // OtherAbstract (a translation) also holds AbstractText.
                if path.contains("Abstract"), !path.contains("OtherAbstract") {
                    buffer = ""
                    label = attributes["Label"]
                }
            case "PublicationType":
                buffer = ""
            default:
                break
            }
            path.append(name)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer? += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            path.removeLast()
            switch name {
            case "PMID":
                if let b = buffer { current?.pmid = b.trimmingCharacters(in: .whitespacesAndNewlines); buffer = nil }
            case "AbstractText":
                // Nested <i> and <sub> end here too, but only this element opened the buffer.
                if let b = buffer {
                    let text = b.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if !text.isEmpty {
                        if let l = label, !l.isEmpty, l != "UNLABELLED", l != "UNASSIGNED" {
                            sections.append("\(l.capitalized): \(text)")
                        } else {
                            sections.append(text)
                        }
                    }
                    buffer = nil
                    label = nil
                }
            case "PublicationType":
                if let b = buffer {
                    current?.publicationTypes.append(b.trimmingCharacters(in: .whitespacesAndNewlines))
                    buffer = nil
                }
            case "PubmedArticle":
                if var r = current, !r.pmid.isEmpty {
                    r.abstract = sections.isEmpty ? nil : sections.joined(separator: " ")
                    records.append(r)
                }
                current = nil
            default:
                break
            }
        }
    }
}

enum Enrich {
    /// Fill missing abstracts and attach publication types. An abstract that
    /// OpenAlex already has is kept: it is the same text, and this way a
    /// PubMed failure can only add information, never change it.
    static func apply(_ records: [PubMedRecord], to papers: [Paper]) -> [Paper] {
        let byPMID = Dictionary(records.map { ($0.pmid, $0) }, uniquingKeysWith: { first, _ in first })
        return papers.map { paper in
            guard let pmid = paper.pmid, let record = byPMID[pmid] else { return paper }
            var p = paper
            if p.abstract == nil, let a = record.abstract {
                p.abstract = a
                p.abstractFromPubMed = true
            }
            p.pubmedTypes = record.publicationTypes
            return p
        }
    }

    /// Record a PMID found by DOI lookup, so the next `apply` can use it.
    static func attach(pmids: [String: String], to papers: [Paper]) -> [Paper] {
        papers.map { paper in
            guard paper.pmid == nil, let doi = paper.doi, let pmid = pmids[doi] else { return paper }
            var p = paper
            p.pmid = pmid
            return p
        }
    }
}
