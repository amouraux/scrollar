import Foundation

/// A folder the user chose, normally in iCloud Drive, that holds PDFs for all their devices. Each
/// device points at the same folder once and keeps the choice as a bookmark, as it does for the sync
/// file, so no iCloud entitlement is needed and the files stay the user's: visible in Files, and
/// deletable there. Nothing here trims it; the local cache (`PDFCache`) is the one with a limit.
/// Methods block (file coordination, iCloud downloads), so call them off the main thread.
enum PDFFolder {
    enum Policy: String, CaseIterable {
        /// The PDFs of papers saved or marked For me: the ones the user chose to keep.
        case saved
        case everything
    }

    private static let bookmarkKey = "pdfFolderBookmark"
    private static let policyKey = "pdfFolderPolicy"

    static var policy: Policy {
        get { Policy(rawValue: UserDefaults.standard.string(forKey: policyKey) ?? "") ?? .saved }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: policyKey) }
    }

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

    /// The folder chosen on an earlier run, if it can still be found.
    static var url: URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: creationOptions) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    @discardableResult
    static func adopt(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: creationOptions) else { return false }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return true
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: bookmarkKey) }

    private static func tag(_ key: String) -> String { String(PDFCache.name(for: key).dropLast(".pdf".count)) }

    /// Run `body` with the folder reachable.
    private static func within<T>(_ body: (URL) -> T?) -> T? {
        guard let folder = url else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return body(folder)
    }

    private static func entries(_ folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    }

    /// Whether this paper's PDF is already in the folder.
    private static func find(_ key: String, in folder: URL) -> URL? {
        let t = tag(key)
        guard let entry = entries(folder).first(where: { PDFNames.isFile($0.lastPathComponent, tag: t) }) else { return nil }
        return folder.appendingPathComponent(PDFNames.realName(entry.lastPathComponent))
    }

    /// The file for a paper, copied into the local cache so the next open needs no folder. A file
    /// iCloud has not downloaded here yet is asked for and waited on a little.
    static func bring(_ key: String) -> URL? {
        within { folder in
            guard let file = find(key, in: folder) else { return nil }
            materialise(file)
            var data: Data?
            var failure: NSError?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &failure) { data = try? Data(contentsOf: $0) }
            guard let data, data.prefix(5) == Data("%PDF-".utf8) else { return nil }
            return PDFCache.store(data, key: key)
        }
    }

    /// Put a PDF in the folder if the policy asks for it and it is not there yet.
    static func offer(_ local: URL, key: String, stem: String) {
        guard policy == .everything || PDFCache.savedKeys().contains(key) else { return }
        _ = within { folder -> Bool? in
            guard find(key, in: folder) == nil else { return true }
            let target = folder.appendingPathComponent(PDFNames.fileName(stem: stem, tag: tag(key)))
            var failure: NSError?
            var ok = false
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &failure) { write in
                ok = (try? FileManager.default.copyItem(at: local, to: write)) != nil
            }
            return ok
        }
    }

    static func usage() -> (count: Int, bytes: Int) {
        within { folder -> (Int, Int)? in
            let pdfs = entries(folder).filter { PDFNames.realName($0.lastPathComponent).hasSuffix(".pdf") }
            let bytes = pdfs.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return (pdfs.count, bytes)
        } ?? (0, 0)
    }

    private static func materialise(_ file: URL) {
        func status() -> URLUbiquitousItemDownloadingStatus? {
            var probe = file
            probe.removeAllCachedResourceValues()
            return try? probe.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
        }
        guard let s = status(), s != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, status() != .current { Thread.sleep(forTimeInterval: 0.2) }
    }
}
