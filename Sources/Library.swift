import Foundation

/// A book to display. Identified by its absolute file URL on this device.
struct Book: Identifiable, Hashable {
    let id: URL
    let title: String
    let author: String
    let category: String
    let relativePath: String
    var url: URL { id }
}

/// Phase 1 library: scans Jorge's active "en danza" OneDrive folder and serves
/// the visible list, merging the cached metadata index (see `BookIndexer`).
///
/// The path is hardcoded for now. Phase 2 will replace it with a user-picked
/// folder + security-scoped bookmark so the app works when sandboxed.
enum Library {
    static let categories = ["Fiction", "Nonfiction"]

    /// The user's real home directory. `homeDirectoryForCurrentUser` is
    /// unavailable on Mac Catalyst, so resolve it from the password database.
    static var homeURL: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Whether a library folder is configured (false on iOS until the user
    /// picks one).
    static var hasFolder: Bool { LibraryFolder.rootURL != nil }

    static var rootURL: URL {
        LibraryFolder.rootURL ?? LibraryFolder.defaultMacURL
    }

    /// An EPUB found on disk, with the fingerprint used for incremental indexing.
    struct ScannedFile {
        let url: URL
        let relativePath: String
        let category: String
        let fileSize: Int64
        let modified: Date
    }

    /// Walks the category folders and returns every `.epub` file found.
    static func scan() -> [ScannedFile] {
        let fm = FileManager.default
        var files: [ScannedFile] = []
        for category in categories {
            let dir = rootURL.appendingPathComponent(category, isDirectory: true)
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator
            where url.pathExtension.lowercased() == "epub" {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                files.append(ScannedFile(
                    url: url,
                    relativePath: relativePath(of: url),
                    category: category,
                    fileSize: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                ))
            }
        }
        return files
    }

    /// Path relative to `rootURL`, e.g. "Nonfiction/Honeybee Democracy.epub".
    static func relativePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(root + "/") {
            return String(full.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    /// Builds the visible list from the cached index, falling back to a
    /// filename-derived title for any file not yet indexed. Fast — no parsing.
    static func cachedBooks() -> [Book] {
        let indexed = Dictionary(
            uniqueKeysWithValues: BookIndexer.load().map { ($0.relativePath, $0) }
        )
        return scan()
            .map { file in
                if let meta = indexed[file.relativePath] {
                    return Book(
                        id: file.url,
                        title: meta.title.isEmpty ? fallbackTitle(file.url) : meta.title,
                        author: meta.authors.joined(separator: ", "),
                        category: meta.category,
                        relativePath: file.relativePath
                    )
                }
                return Book(
                    id: file.url,
                    title: fallbackTitle(file.url),
                    author: "",
                    category: file.category,
                    relativePath: file.relativePath
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Maps a fresh index into the visible list (used after a refresh).
    static func books(from indexed: [IndexedBook]) -> [Book] {
        let byPath = Dictionary(uniqueKeysWithValues: scan().map { ($0.relativePath, $0.url) })
        return indexed
            .compactMap { meta -> Book? in
                guard let url = byPath[meta.relativePath] else { return nil }
                return Book(
                    id: url,
                    title: meta.title.isEmpty ? fallbackTitle(url) : meta.title,
                    author: meta.authors.joined(separator: ", "),
                    category: meta.category,
                    relativePath: meta.relativePath
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func fallbackTitle(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
