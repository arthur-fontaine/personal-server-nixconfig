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
            .aspectRatio(PetSize.spriteRatio, contentMode: .fit)
            .frame(width: size.width, height: size.width)
            .clipShape(Circle())
            .contentShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Pet"))
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("pet.avatar")
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
    ///
    /// `heart`: after a caress (design-rules 11.3), a tiny heart in the pet's colour at its
    /// top-trailing corner, drawn into the same image so the item stays the bar's circle.
    static func toolbarImage(_ frame: CGImage, centering: PetCentering = .identity, heart accent: PetAccent? = nil) -> Image {
        Image(uiImage: toolbarUIImage(frame, centering: centering, heart: accent)).renderingMode(.original)
    }

    /// The same, for UIKit's bar button: the pet centred optically in the bar's 36-pt circle
    /// (design-rules 14.2), drawn into the square image the bar centres in it.
    static func toolbarUIImage(_ frame: CGImage, centering: PetCentering = .identity, heart accent: PetAccent? = nil) -> UIImage {
        let side = PetSize.toolbar.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = UITraitCollection.current.displayScale
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            let rect = centering.drawRect(cell: CGSize(width: frame.width, height: frame.height), canvas: side, circle: Metric.barItem)
            UIImage(cgImage: frame).draw(in: rect)
            if let accent {
                let colour = accent.shades[PetAccent.Appearance(UITraitCollection.current)]!.accent.uiColor
                let config = UIImage.SymbolConfiguration(pointSize: HeartBadge.pointSize, weight: .bold)
                if let heart = UIImage(systemName: "heart.fill", withConfiguration: config)?.withTintColor(colour, renderingMode: .alwaysOriginal) {
                    heart.draw(at: CGPoint(x: side - heart.size.width, y: 0))
                }
            }
        }
    }
}
