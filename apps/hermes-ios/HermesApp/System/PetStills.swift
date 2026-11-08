import HermesCore
import HermesUI
import Foundation

/// Writes the pet's stills next to its sheet in the app group, once per pet version: the widget
/// extension and the Live Activity load these small PNGs (round 5: the compact Island showed the
/// fallback symbol, the sheet not decoding there).
enum PetStills {
    static func ensure(sheet name: String, source: URL, group: String?) {
        guard let sheet = SpriteSheet.cached(url: source) else { return }
        let centering = PetCentering(frames: PetAnimation.allCases.compactMap { sheet.frame($0, 0) })
        for animation in PetAnimation.allCases {
            guard let frame = sheet.frame(animation, 0) else { continue }
            for circle in [false, true] {
                guard let url = SharedContainer.stillURL(sheet: name, animation: animation, circle: circle, group: group),
                      !FileManager.default.fileExists(atPath: url.path),
                      let png = PetStill.png(frame: frame, centering: centering, inCircle: circle) else { continue }
                try? png.write(to: url, options: .atomic)
            }
        }
    }
}
