import CoreGraphics
import Foundation
import Testing
@testable import HermesCore

/// A sheet's background-removal halo goes at decode: every pixel opaque or clear.
@Suite("Sprite sheet")
struct SpriteSheetTests {
    @Test func aHaloIsClearedAndAnEdgeMadeOpaque() throws {
        // Three pixels: the halo (alpha 30), an edge (alpha 200), the body (opaque).
        var pixels: [UInt8] = [12, 12, 12, 30, 150, 150, 150, 200, 255, 255, 255, 255]
        let ctx = try #require(CGContext(data: &pixels, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        let out = try #require(SpriteSheet.hardened(image))
        let data = try #require(out.dataProvider?.data as Data?)
        #expect(data[3] == 0 && data[0] == 0, "the halo is clear")
        #expect(data[7] == 255 && data[4] == 191, "the edge is opaque, its colour unpremultiplied")
        #expect(Array(data[8..<12]) == [255, 255, 255, 255])
    }

    @Test func aLightRimOnAnOutlineTakesTheOutlinesColour() throws {
        // clear | grey rim (36) | black outline (3) | white body
        var pixels: [UInt8] = [0, 0, 0, 0, 36, 36, 36, 255, 3, 3, 3, 255, 250, 250, 250, 255]
        let ctx = try #require(CGContext(data: &pixels, width: 4, height: 1, bitsPerComponent: 8, bytesPerRow: 16,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        let out = try #require(SpriteSheet.hardened(image))
        let data = try #require(out.dataProvider?.data as Data?)
        #expect(data[4] == 3, "the rim is the outline's black")
        #expect(data[12] == 250, "the body isn't touched")
    }
}
