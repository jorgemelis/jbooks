import Foundation

/// Persists the list of recently opened books (most recent first), keyed by
/// relative path. Device-local for now; a candidate for CloudKit sync later.
enum RecentsStore {
    private static let key = "recentBooks"
    private static let cap = 60

    static func items() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Records an opened book, moving it to the front (de-duplicated).
    static func add(_ relativePath: String) {
        var list = items().filter { $0 != relativePath }
        list.insert(relativePath, at: 0)
        UserDefaults.standard.set(Array(list.prefix(cap)), forKey: key)
    }

    /// Removes a book from recents (does NOT touch the file or the library).
    static func remove(_ relativePath: String) {
        UserDefaults.standard.set(items().filter { $0 != relativePath }, forKey: key)
    }
}
