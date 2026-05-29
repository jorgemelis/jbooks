import Foundation
import ReadiumShared

/// Persists the last reading position per book, keyed by the book's path
/// relative to the library root (stable across devices).
///
/// Phase 1 uses `UserDefaults` (device-local). Phase 3+ moves this to the
/// CloudKit-synced `ReadingPosition` log from the brief.
enum PositionStore {
    private static var defaults: UserDefaults { .standard }

    private static func key(_ relativePath: String) -> String {
        "position:" + relativePath
    }

    static func locator(forRelativePath path: String) -> Locator? {
        guard let string = defaults.string(forKey: key(path)) else { return nil }
        return try? Locator(jsonString: string)
    }

    static func save(_ locator: Locator, forRelativePath path: String) {
        guard let string = try? locator.jsonString() else { return }
        defaults.set(string, forKey: key(path))
    }
}
