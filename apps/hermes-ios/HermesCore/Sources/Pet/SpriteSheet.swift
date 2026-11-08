import CoreGraphics
import Foundation
import ImageIO

/// A decoded Codex atlas, cut into frames on demand and cached. Shared by the app (animated) and
/// the widgets (one still frame), so it uses ImageIO, not UIKit.
public final class SpriteSheet: @unchecked Sendable {
    public let layout: PetAtlasLayout
    private let image: CGImage
    private var cache: [Int: CGImage] = [:]
    private let lock = NSLock()

    public convenience init?(url: URL, layout: PetAtlasLayout = .codex) {
        guard let image = Self.decode(url) else { return nil }
        self.init(image: image, layout: layout)
    }

    public static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
    }

    public init(image: CGImage, layout: PetAtlasLayout = .codex) {
        self.image = image
        // A sheet of another size keeps the 8×9 grid: cells scale with it.
        if image.width != layout.columns * layout.cellWidth {
            self.layout = PetAtlasLayout(columns: layout.columns, cellWidth: image.width / layout.columns,
                                         cellHeight: image.height / PetAnimation.allCases.count)
        } else {
            self.layout = layout
        }
    }

    public func frame(_ animation: PetAnimation, _ index: Int) -> CGImage? {
        let key = animation.row * 16 + index % max(animation.frameCount, 1)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let cropped = image.cropping(to: layout.frameRect(animation, frame: index))
        cache[key] = cropped
        return cropped
    }

    // One decoded sheet per file: the chat header, the sidebar and the pet screen share it.
    nonisolated(unsafe) private static var shared: [URL: SpriteSheet] = [:]
    private static let sharedLock = NSLock()

    /// Puts a sheet in the cache for a file (the demo's recoloured pet).
    public static func register(_ sheet: SpriteSheet, for url: URL) {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        shared[url] = sheet
    }

    public static func cached(url: URL) -> SpriteSheet? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let s = shared[url] { return s }
        let s = SpriteSheet(url: url)
        shared[url] = s
        return s
    }
}
