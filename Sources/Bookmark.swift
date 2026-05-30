import Foundation
import ReadiumShared

/// A user bookmark inside a book, with an editable name.
struct Bookmark: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var locatorJSON: String

    var locator: Locator? {
        try? Locator(jsonString: locatorJSON)
    }

    /// A sensible default name from the locator: the chapter title, else the
    /// page number, else the reading progress.
    static func defaultName(for locator: Locator) -> String {
        if let title = locator.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let position = locator.locations.position {
            return "Página \(position)"
        }
        if let progression = locator.locations.totalProgression {
            return "\(Int((progression * 100).rounded()))%"
        }
        return "Marcador"
    }
}

/// Persists bookmarks per book (keyed by relative path). Device-local for now;
/// a candidate for CloudKit sync later.
enum BookmarksStore {
    private static func key(_ relativePath: String) -> String { "bookmarks:" + relativePath }

    static func bookmarks(forRelativePath path: String) -> [Bookmark] {
        guard let data = UserDefaults.standard.data(forKey: key(path)) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    private static func save(_ list: [Bookmark], forRelativePath path: String) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key(path))
        }
    }

    static func add(_ bookmark: Bookmark, forRelativePath path: String) {
        var list = bookmarks(forRelativePath: path)
        list.insert(bookmark, at: 0)
        save(list, forRelativePath: path)
    }

    static func remove(id: UUID, forRelativePath path: String) {
        save(bookmarks(forRelativePath: path).filter { $0.id != id }, forRelativePath: path)
    }

    static func rename(id: UUID, to name: String, forRelativePath path: String) {
        var list = bookmarks(forRelativePath: path)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = name
        save(list, forRelativePath: path)
    }
}
