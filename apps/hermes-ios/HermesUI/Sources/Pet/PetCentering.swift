import CoreGraphics
import UIKit
import SwiftUI

/// Optical centring of the pet (design-rules 14.2). A sprite cell has the character somewhere in
/// it, often off-centre (antennae, wings, a shadow under the feet), so centring the cell doesn't
/// centre the pet. This reads the frames a container can show, once per pet version:
/// - the **union box** of their opaque pixels (alpha > `alphaThreshold`),
/// - their **alpha-weighted centroid**,
///
/// and places the box's centre — nudged vertically by `opticalBias` toward the centroid, where
/// the eye puts the figure's weight — at the container's centre, scaled so the box fills the
/// circle's inscribed square (or the frame, for a container that isn't a circle).
public struct PetCentering: Equatable, Sendable {
    /// In the cell's unit space (0…1, y down).
    let box: CGRect
    let centroid: CGPoint

    /// How far from the box's centre toward the centroid the anchor moves, vertically.
    static let opticalBias: CGFloat = 0.3
    static let alphaThreshold: UInt8 = 40

    /// The whole cell, for a sprite with nothing opaque.
    public static let identity = PetCentering(box: unitCell, centroid: CGPoint(x: unitCell.midX, y: unitCell.midY))
    /// The cell in its own unit space.
    static let unitCell = CGRect(origin: .zero, size: CGSize(width: Metric.square, height: Metric.square))

    init(box: CGRect, centroid: CGPoint) {
        self.box = box
        self.centroid = centroid
    }

    /// From the frames a container shows (all the same cell size).
    public init(frames: [CGImage]) {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var sx = 0.0, sy = 0.0, sa = 0.0
        var cellW = 1, cellH = 1
        for image in frames {
            let w = image.width, h = image.height
            cellW = w; cellH = h
            var data = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            // A bitmap context's memory rows run top-down once the image is drawn upright.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            for y in 0..<h {
                for x in 0..<w {
                    let alpha = data[(y * w + x) * 4 + 3]
                    guard alpha > Self.alphaThreshold else { continue }
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    let a = Double(alpha)
                    sx += (Double(x) + 0.5) * a; sy += (Double(y) + 0.5) * a; sa += a
                }
            }
        }
        guard maxX >= 0, sa > 0 else { self = .identity; return }
        let W = CGFloat(cellW), H = CGFloat(cellH)
        // Inclusive pixel bounds: the last pixel counts, so its span is (max − min) + one pixel.
        let spanX = CGFloat(maxX - minX) + Metric.pixel, spanY = CGFloat(maxY - minY) + Metric.pixel
        box = CGRect(x: CGFloat(minX) / W, y: CGFloat(minY) / H, width: spanX / W, height: spanY / H)
        centroid = CGPoint(x: sx / sa / W, y: sy / sa / H)
    }

    nonisolated(unsafe) private static var cache: [String: PetCentering] = [:]
    private static let lock = NSLock()

    /// One computation per pet version and container (`key`).
    public static func cached(_ key: String, frames: () -> [CGImage]) -> PetCentering {
        lock.lock()
        if let c = cache[key] { lock.unlock(); return c }
        lock.unlock()
        let c = PetCentering(frames: frames())
        lock.lock(); cache[key] = c; lock.unlock()
        return c
    }

    /// The point of the cell (unit space) to put at the container's centre.
    var anchor: CGPoint {
        CGPoint(x: box.midX, y: box.midY + (centroid.y - box.midY) * Self.opticalBias)
    }

    /// Where to draw a `cell`-sized frame in a square canvas of side `canvas`, so the box fits the
    /// inscribed square of a circle of `circle` diameter centred on the canvas (`circle == nil`:
    /// fits the canvas itself).
    func drawRect(cell: CGSize, canvas: CGFloat, circle: CGFloat?) -> CGRect {
        let fit = circle.map { $0 / 2.squareRoot() } ?? canvas
        let boxW = box.width * cell.width, boxH = box.height * cell.height
        let scale = fit / max(boxW, boxH)
        let size = CGSize(width: cell.width * scale, height: cell.height * scale)
        return CGRect(x: canvas / 2 - anchor.x * size.width, y: canvas / 2 - anchor.y * size.height,
                      width: size.width, height: size.height)
    }
}

/// A pet frame centred optically in a square container: the circle it sits in (`inCircle`), or
/// the square itself. Pixel art kept sharp, scaled uniformly.
public struct CenteredPet: View {
    let frame: CGImage
    let centering: PetCentering
    let inCircle: Bool

    public init(frame: CGImage, centering: PetCentering, inCircle: Bool = true) {
        self.frame = frame
        self.centering = centering
        self.inCircle = inCircle
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = centering.drawRect(cell: CGSize(width: frame.width, height: frame.height),
                                       canvas: side, circle: inCircle ? side : nil)
            let dx = (geo.size.width - side) / 2, dy = (geo.size.height - side) / 2
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX + dx, y: r.midY + dy)
        }
        .aspectRatio(Metric.square, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A still of the pet, centred optically and pixel-exact, as a PNG — for the widgets and the
/// Live Activity, which load it instead of decoding the whole sheet in their small memory budget.
public enum PetStill {
    public static func png(frame: CGImage, centering: PetCentering, inCircle: Bool) -> Data? {
        let side = Metric.stillPixels
        guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        let r = centering.drawRect(cell: CGSize(width: frame.width, height: frame.height), canvas: side,
                                   circle: inCircle ? side : nil)
        // Core Graphics' origin is at the bottom left.
        ctx.draw(frame, in: CGRect(x: r.minX, y: side - r.maxY, width: r.width, height: r.height))
        guard let image = ctx.makeImage() else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}
