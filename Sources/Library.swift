import Foundation

/// A book discovered on disk. Identified by its file URL.
struct Book: Identifiable, Hashable {
    let id: URL
    let title: String
    let category: String
    var url: URL { id }
}

/// Phase 1 library: scans Jorge's active "en danza" OneDrive folder.
///
/// This path is hardcoded for now. Phase 2 will replace it with a user-picked
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

    static var rootURL: URL {
        homeURL.appendingPathComponent(
            "Library/CloudStorage/OneDrive-Personal/_books/2read",
            isDirectory: true
        )
    }

    static func loadBooks() -> [Book] {
        let fm = FileManager.default
        var books: [Book] = []
        for category in categories {
            let dir = rootURL.appendingPathComponent(category, isDirectory: true)
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator
            where url.pathExtension.lowercased() == "epub" {
                books.append(Book(
                    id: url,
                    title: url.deletingPathExtension().lastPathComponent,
                    category: category
                ))
            }
        }
        return books.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}
