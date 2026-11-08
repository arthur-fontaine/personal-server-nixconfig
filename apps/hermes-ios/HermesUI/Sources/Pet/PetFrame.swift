import SwiftUI
import UIKit

/// The pet as an avatar (design-rules 10.2): a square box, the sprite scaled uniformly to fit
/// it (pixel art kept sharp), clipped by a circle — round by construction, at every size.
public struct PetAvatar<Sprite: View>: View {
    let size: PetSize
    let sprite: Sprite

    public init(_ size: PetSize, @ViewBuilder sprite: () -> Sprite) {
        self.size = size
        self.sprite = sprite()
    }

    public var body: some View {
        sprite
            .aspectRatio(1 / PetSize.aspect, contentMode: .fit)
            .frame(width: size.width, height: size.width)
            .clipShape(Circle())
            .contentShape(Circle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isImage)
    }
}

/// The sidebar column's width on iPad.
public extension View {
    func sidebarColumnWidth() -> some View {
        navigationSplitViewColumnWidth(min: Metric.sidebarMin, ideal: Metric.sidebarIdeal, max: Metric.sidebarMax)
    }
}

public extension PetAvatar where Sprite == EmptyView {
    /// The pet for a toolbar item: a still frame drawn into a square image, the sprite scaled
    /// uniformly with no interpolation. An `Image` is what the bar draws inside its own circular
    /// glass item (design-rules 10.3); a custom view would get a capsule.
    static func toolbarImage(_ frame: CGImage) -> Image {
        let side = PetSize.toolbar.width
        let scale = UITraitCollection.current.displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            let h = side, w = side / PetSize.aspect
            // Core Graphics draws bottom-up: flip so the sprite stands upright.
            ctx.cgContext.translateBy(x: 0, y: side)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            ctx.cgContext.draw(frame, in: CGRect(x: (side - w) / 2, y: 0, width: w, height: h))
        }
        return Image(uiImage: image).renderingMode(.original)
    }
}
