import UIKit
import CryptoKit

/// Disk + memory cache for book cover thumbnails.
///
/// Thumbnails live in a plain `covers/` directory inside the project folder
/// (`~/claude/jbooks/covers`) — no hidden system Library caches. Delete the
/// project folder and everything goes with it. Keyed by the book's relative
/// path, normalized to NFC so the key matches whether the path came from the
/// filesystem (NFD on macOS) or the JSON index.
final class CoverCache {
    static let shared = CoverCache()

    /// Target thumbnail size in pixels (retina-sharp for a ~46pt-wide row).
    static let pixelSize = CGSize(width: 200, height: 300)

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL

    private init() {
        let base = Library.homeURL.appendingPathComponent("claude/jbooks", isDirectory: true)
        directory = base.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for relativePath: String) -> URL {
        let key = relativePath.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".jpg", isDirectory: false)
    }

    func has(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: relativePath).path)
    }

    func store(_ image: UIImage, for relativePath: String) {
        let key = relativePath.precomposedStringWithCanonicalMapping as NSString
        memory.setObject(image, forKey: key)
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: fileURL(for: relativePath), options: .atomic)
        }
    }

    func image(for relativePath: String) -> UIImage? {
        let key = relativePath.precomposedStringWithCanonicalMapping as NSString
        if let cached = memory.object(forKey: key) { return cached }
        guard
            let data = try? Data(contentsOf: fileURL(for: relativePath)),
            let image = UIImage(data: data)
        else { return nil }
        memory.setObject(image, forKey: key)
        return image
    }
}
