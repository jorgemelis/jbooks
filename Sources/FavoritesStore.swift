import Foundation

/// Persists the user's manually chosen favorite books, keyed by relative path.
/// Separate from `RecentsStore` (recents auto-fill on open; favorites are
/// explicit). Device-local for now; a candidate for CloudKit sync later.
enum FavoritesStore {
    private static let key = "favoriteBooks"

    static func items() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func contains(_ relativePath: String) -> Bool {
        items().contains(relativePath)
    }

    static func toggle(_ relativePath: String) {
        var list = items()
        if let index = list.firstIndex(of: relativePath) {
            list.remove(at: index)
        } else {
            list.insert(relativePath, at: 0)
        }
        UserDefaults.standard.set(list, forKey: key)
    }
}
