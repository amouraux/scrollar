import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The sync file the user chose, in iCloud Drive or anywhere else. It is kept as a
/// bookmark, and read and written through file coordination, because iCloud may be
/// replacing the file while this runs. The merging is in Core/Sync.swift; this is only
/// the file. Methods block, so call them off the main thread.
struct SyncFile: Sendable {
    let url: URL

    private static let bookmarkKey = "syncFileBookmark"

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if targetEnvironment(macCatalyst)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if targetEnvironment(macCatalyst)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    // MARK: Remembering the file

    /// The file chosen on an earlier run, if it can still be found.
    static func stored() -> SyncFile? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            // Moved or deleted: forget it, rather than failing at every sync from here on.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: creationOptions) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return SyncFile(url: url)
    }

    /// Point the app at `url` from now on.
    static func adopt(_ url: URL) -> SyncFile? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: creationOptions) else { return nil }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return SyncFile(url: url)
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: bookmarkKey) }

    var name: String { url.lastPathComponent }

    // MARK: Reading

    enum Problem: Equatable {
        case newerFormat(Int)
        case notASyncFile
        case unreachable

        var message: String {
            switch self {
            case .newerFormat: return "This sync file was saved by a newer Scrollar. Update this device; nothing was read from it or written to it."
            case .notASyncFile: return "That file is not a Scrollar sync file, so it was left alone."
            case .unreachable: return "The sync file could not be read. If it is in iCloud Drive, it may still be downloading."
            }
        }
    }

    struct Outcome {
        /// The file as it is now, if it holds a document.
        var main: SyncDocument?
        /// Copies iCloud parked because two devices wrote at once, which must be merged too.
        var conflicts: [SyncDocument] = []
        var hadConflictVersions = false
        var problem: Problem?
    }

    func read() -> Outcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        SyncFile.materialise(url)

        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        guard let data else { return Outcome(problem: .unreachable) }

        var outcome = Outcome()
        switch SyncDocument.read(data) {
        case .empty: break
        case .document(let doc): outcome.main = doc
        case .newerFormat(let n): outcome.problem = .newerFormat(n); return outcome
        case .unreadable: outcome.problem = .notASyncFile; return outcome
        }
        // iCloud keeps one write as the file and parks the other as a conflict version.
        // Reading only the file would lose what the other device wrote.
        if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty {
            outcome.hadConflictVersions = true
            for version in versions {
                if let d = try? Data(contentsOf: version.url), case .document(let doc) = SyncDocument.read(d) {
                    outcome.conflicts.append(doc)
                }
            }
        }
        return outcome
    }

    // MARK: Writing

    /// Only after the merged result is safely written are the parked copies marked
    /// resolved, so a failed write cannot lose the copy it came from.
    func write(_ data: Data, resolvingConflicts: Bool) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var ok = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            ok = (try? data.write(to: writeURL, options: .atomic)) != nil
        }
        if ok, resolvingConflicts, let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) {
            for version in versions { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        return ok
    }

    /// A file in iCloud Drive may be a placeholder until something asks for it, and
    /// reading one without asking gives nothing, which looks exactly like an empty file.
    private static func materialise(_ url: URL) {
        func values(_ keys: Set<URLResourceKey>) -> URLResourceValues? {
            var probe = url
            probe.removeAllCachedResourceValues()
            return try? probe.resourceValues(forKeys: keys)
        }
        guard values([.isUbiquitousItemKey])?.isUbiquitousItem == true else { return }
        if values([.ubiquitousItemDownloadingStatusKey])?.ubiquitousItemDownloadingStatus == .current { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if values([.ubiquitousItemDownloadingStatusKey])?.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }
}

/// What the "create the sync file" dialog saves: the current state, so the file is
/// never empty and a second device that joins it gets everything.
struct SyncFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
