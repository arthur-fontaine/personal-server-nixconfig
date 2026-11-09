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
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return nil }
        return hardened(image) ?? image
    }

    /// Pixel art is opaque or clear. A generated pet's sheet keeps a faint grey halo from its
    /// background removal, a light line around the pet on a dark screen: every pixel becomes
    /// clear below half alpha, opaque above (its colour unpremultiplied). Once, at decode, so
    /// every view of the pet (launch, chat, pet screen, stills) draws it clean.
    static func hardened(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = Int(data[i + 3])
            if a < 128 {
                data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 0
            } else if a < 255 {
                for c in 0..<3 { data[i + c] = UInt8(min(255, Int(data[i + c]) * 255 / a)) }
                data[i + 3] = 255
            }
        }
        darkenRim(data, width: w, height: h)
        return ctx.makeImage()
    }

    /// The cut-out's rim: an opaque pixel next to the clear area, lighter than the darkest
    /// opaque pixel around it while that one is dark (an outline), is the removal's grey fringe,
    /// not the drawing: it takes the outline's colour. Visible on a large pet (the launch screen).
    /// How much lighter than the outline (summed over R, G, B) a rim pixel may be. Small: on a
    /// black OLED screen even a pixel at 19/255 next to the outline shows as a grey line.
    static let rimTolerance = 12

    static func darkenRim(_ data: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int) {
        func lum(_ i: Int) -> Int { Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2]) }
        var changes: [(Int, Int)] = []
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard data[i + 3] == 255 else { continue }
                var rim = false, darkest = -1, darkestLum = Int.max
                // The fringe is up to two pixels wide: the rim is what lies within two pixels of
                // the clear area, measured against the darkest opaque pixel as far.
                for dy in -2...2 {
                    for dx in -2...2 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let j = (ny * w + nx) * 4
                        if data[j + 3] == 0 { rim = true; continue }
                        let l = lum(j)
                        if l < darkestLum { darkestLum = l; darkest = j }
                    }
                }
                if rim, darkest >= 0, darkestLum < 3 * 80, lum(i) > darkestLum + Self.rimTolerance { changes.append((i, darkest)) }
            }
        }
        // Applied after the scan: a fixed pixel never decides its neighbour's fate.
        for (i, j) in changes { for c in 0..<3 { data[i + c] = data[j + c] } }
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
