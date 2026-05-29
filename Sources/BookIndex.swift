import Foundation
import ReadiumShared
import ReadiumStreamer

/// One book's metadata, as persisted in the JSON index.
///
/// Keyed by `relativePath` (relative to the 2read root) so the index is
/// portable across devices, whose absolute library paths differ.
struct IndexedBook: Codable, Hashable {
    var relativePath: String
    var category: String
    var title: String
    var authors: [String]
    var identifier: String?
    /// Whether the EPUB carried a usable embedded title. When false the UI
    /// falls back to a filename-derived title.
    var hasTitle: Bool
    /// File fingerprint for incremental rebuilds.
    var fileSize: Int64
    var modified: Date
}

/// On-disk index file: `<2read>/.jbooks-index.json`.
struct BookIndexFile: Codable {
    var version: Int
    var books: [IndexedBook]
}

enum BookIndexer {
    static let fileName = ".jbooks-index.json"
    static let currentVersion = 2

    static var indexURL: URL {
        Library.rootURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Loads the raw index file (nil if absent or unreadable).
    static func loadFile() -> BookIndexFile? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? decoder.decode(BookIndexFile.self, from: data)
    }

    /// Loads the cached entries. Returns [] if absent or unreadable.
    static func load() -> [IndexedBook] {
        loadFile()?.books ?? []
    }

    /// Strips a trailing "(ISBN)" that some publishers leave in `dc:title`,
    /// e.g. "Charlemagne (9780674973411)" → "Charlemagne". Only removes a
    /// trailing parenthetical whose digits form a 10- or 13-char ISBN, so
    /// legitimate parentheticals like "(2nd Edition)" are left alone.
    static func sanitizeTitle(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix(")"), let open = t.range(of: "(", options: .backwards) else { return t }
        let inner = t[t.index(after: open.lowerBound) ..< t.index(before: t.endIndex)]
        let digits = inner.filter { !" -".contains($0) }
        let isISBN = (digits.count == 10 || digits.count == 13)
            && digits.dropLast().allSatisfy(\.isNumber)
            && (digits.last.map { $0.isNumber || "Xx".contains($0) } ?? false)
        guard isISBN else { return t }
        return String(t[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rebuilds the index incrementally: reuses entries whose file fingerprint
    /// is unchanged, parses only new/modified files, prunes deleted ones, then
    /// writes the index atomically. Intended to run on the Mac, where the whole
    /// library is downloaded.
    ///
    /// Returns the refreshed entries plus the relative paths that failed to
    /// open (candidates for a Calibre round-trip).
    static func refresh(
        progress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> (books: [IndexedBook], failed: [String]) {
        let files = Library.scan()
        // Reuse cached entries only when the schema version matches; otherwise
        // force a full rebuild so changes like title sanitization take effect.
        let cached = loadFile()
        let previous: [String: IndexedBook] = (cached?.version == currentVersion)
            ? Dictionary(uniqueKeysWithValues: (cached?.books ?? []).map { ($0.relativePath, $0) })
            : [:]

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        var books: [IndexedBook] = []
        var failed: [String] = []
        let total = files.count

        for (i, file) in files.enumerated() {
            if let prev = previous[file.relativePath],
               prev.fileSize == file.fileSize,
               prev.modified == file.modified {
                books.append(prev)
            } else if let entry = await indexOne(file, opener: opener, assetRetriever: assetRetriever) {
                books.append(entry)
            } else {
                failed.append(file.relativePath)
            }
            if let progress { await progress(i + 1, total) }
        }

        books.sort { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
        write(books)
        return (books, failed)
    }

    private static func indexOne(
        _ file: Library.ScannedFile,
        opener: PublicationOpener,
        assetRetriever: AssetRetriever
    ) async -> IndexedBook? {
        guard let fileURL = FileURL(url: file.url) else { return nil }
        guard case let .success(asset) = await assetRetriever.retrieve(url: fileURL) else { return nil }
        guard case let .success(publication) = await opener.open(asset: asset, allowUserInteraction: false) else {
            return nil
        }

        let rawTitle = publication.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanTitle = sanitizeTitle(rawTitle)
        let hasTitle = !cleanTitle.isEmpty
        return IndexedBook(
            relativePath: file.relativePath,
            category: file.category,
            title: hasTitle ? cleanTitle : file.url.deletingPathExtension().lastPathComponent,
            authors: publication.metadata.authors.map(\.name),
            identifier: publication.metadata.identifier,
            hasTitle: hasTitle,
            fileSize: file.fileSize,
            modified: file.modified
        )
    }

    /// Atomic write (temp + rename, handled by `.atomic`) so a cloud-sync
    /// daemon never observes a half-written file.
    private static func write(_ books: [IndexedBook]) {
        let file = BookIndexFile(version: currentVersion, books: books)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
