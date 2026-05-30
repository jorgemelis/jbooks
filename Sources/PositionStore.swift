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

    // MARK: - Position history (the "log" from the brief)

    private static let historyCap = 25
    private static func historyKey(_ path: String) -> String { "history:" + path }

    /// Recent reading positions, most recent first.
    static func history(forRelativePath path: String) -> [Locator] {
        (defaults.stringArray(forKey: historyKey(path)) ?? [])
            .compactMap { try? Locator(jsonString: $0) }
    }

    /// Appends a position to the history (most recent first), capped.
    static func recordHistory(_ locator: Locator, forRelativePath path: String) {
        guard let string = try? locator.jsonString() else { return }
        var list = defaults.stringArray(forKey: historyKey(path)) ?? []
        list.insert(string, at: 0)
        defaults.set(Array(list.prefix(historyCap)), forKey: historyKey(path))
    }
}
