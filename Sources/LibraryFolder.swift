import Foundation

/// Resolves the library root folder.
///
/// - On Mac Catalyst (non-sandboxed) it defaults to Jorge's OneDrive `2read`
///   path, so nothing needs picking.
/// - On iOS that path doesn't exist, so the user picks the folder once with a
///   document picker; we persist a security-scoped bookmark and reuse it.
enum LibraryFolder {
    private static let bookmarkKey = "libraryFolderBookmark"

    /// The default Mac path. Present only on the Mac.
    static var defaultMacURL: URL {
        Library.homeURL.appendingPathComponent(
            "Library/CloudStorage/OneDrive-Personal/_books/2read",
            isDirectory: true
        )
    }

    /// The configured root folder, or nil if the user still needs to pick one.
    static var rootURL: URL? {
        #if targetEnvironment(macCatalyst)
        if FileManager.default.fileExists(atPath: defaultMacURL.path) {
            return defaultMacURL
        }
        #endif
        return resolveBookmark()
    }

    /// Stores the user-picked folder as a security-scoped bookmark.
    static func setFolder(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    private static func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        // Keep access open for the app's lifetime (released on termination).
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}
