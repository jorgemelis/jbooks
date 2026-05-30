import Foundation
import UIKit
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
            let prev = previous[file.relativePath]
            let metaFresh = prev.map { $0.fileSize == file.fileSize && $0.modified == file.modified } ?? false
            let coverExists = CoverCache.shared.has(file.relativePath)

            if metaFresh, coverExists, let prev {
                // Nothing to do — reuse the cached entry without opening the file.
                books.append(prev)
            } else if let entry = await openAndIndex(
                file,
                reusing: metaFresh ? prev : nil,
                extractCover: !coverExists,
                opener: opener,
                assetRetriever: assetRetriever
            ) {
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

    /// Opens the publication once to (re)build its metadata entry and/or
    /// extract its cover thumbnail. Returns nil if the file can't be opened.
    ///
    /// When `reusing` is non-nil the metadata is kept as-is (the file was only
    /// reopened to generate a missing cover).
    private static func openAndIndex(
        _ file: Library.ScannedFile,
        reusing existing: IndexedBook?,
        extractCover: Bool,
        opener: PublicationOpener,
        assetRetriever: AssetRetriever
    ) async -> IndexedBook? {
        guard let fileURL = FileURL(url: file.url) else { return nil }
        guard case let .success(asset) = await assetRetriever.retrieve(url: fileURL) else { return nil }
        guard case let .success(publication) = await opener.open(asset: asset, allowUserInteraction: false) else {
            return nil
        }

        if extractCover, let image = await coverImage(for: publication) {
            CoverCache.shared.store(image, for: file.relativePath)
        }

        if let existing { return existing }

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

    /// Returns a cover thumbnail for the publication. First tries Readium's
    /// detector (declared `cover` rel or first reading-order image); if that
    /// finds nothing, falls back to any embedded bitmap whose path contains
    /// "cover" — covers many EPUBs that ship a cover image without declaring
    /// it in the OPF (which is why Readium misses them).
    private static func coverImage(for publication: Publication) async -> UIImage? {
        // 1) Readium's detector (declared `cover` rel or first reading-order image).
        if case let .success(image) = await publication.coverFitting(maxSize: CoverCache.pixelSize),
           let image {
            return image
        }
        let all = publication.readingOrder + publication.resources + publication.links

        // 2) A bitmap whose own path mentions "cover".
        for link in all where link.mediaType?.isBitmap == true && link.href.lowercased().contains("cover") {
            if let image = await loadImage(link, from: publication) { return image }
        }

        // 3) A "cover" HTML page that references an image (common when the OPF
        //    doesn't declare the cover, so Readium misses it).
        for page in all where isHTML(page) && page.href.lowercased().contains("cover") {
            guard
                let resource = publication.get(page),
                let data = try? await resource.read().get(),
                let html = String(data: data, encoding: .utf8),
                let ref = firstImageReference(in: html)
            else { continue }
            let decodedRef = ref.removingPercentEncoding ?? ref
            let target = (decodedRef as NSString).lastPathComponent
            guard !target.isEmpty, let link = all.first(where: {
                $0.mediaType?.isBitmap == true
                    && ((($0.href.removingPercentEncoding ?? $0.href) as NSString).lastPathComponent == target)
            }) else { continue }
            if let image = await loadImage(link, from: publication) { return image }
        }
        return nil
    }

    private static func loadImage(_ link: Link, from publication: Publication) async -> UIImage? {
        guard
            let resource = publication.get(link),
            let data = try? await resource.read().get(),
            let image = UIImage(data: data),
            min(image.size.width, image.size.height) >= 200
        else { return nil }
        return downscale(image, maxSize: CoverCache.pixelSize)
    }

    private static func isHTML(_ link: Link) -> Bool {
        let h = link.href.lowercased()
        return h.hasSuffix(".xhtml") || h.hasSuffix(".html") || h.hasSuffix(".htm")
    }

    private static func firstImageReference(in html: String) -> String? {
        let pattern = #"(?:src|xlink:href|href)\s*=\s*["']([^"']+\.(?:jpe?g|png|gif))["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard
            let match = regex.firstMatch(in: html, range: range),
            let captured = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[captured])
    }

    private static func downscale(_ image: UIImage, maxSize: CGSize) -> UIImage {
        let scale = min(maxSize.width / image.size.width, maxSize.height / image.size.height, 1)
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Atomic write (temp + rename, handled by `.atomic`) so a cloud-sync
    /// daemon never observes a half-written file.
    private static func write(_ books: [IndexedBook]) {
        let file = BookIndexFile(version: currentVersion, books: books)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
