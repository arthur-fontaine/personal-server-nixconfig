import SwiftUI

/// An icon-only button in the content layer (design-rules 10.1): a circle of a token size, the
/// neutral fill, round by construction (its frame is a square, its shape a `Circle`, used for
/// fill and hit alike). No width or height parameter exists.
public struct IconButton: View {
    let title: Text
    let systemImage: String
    let size: IconSize
    let action: () -> Void

    public init(_ title: LocalizedStringKey, systemImage: String, size: IconSize = .regular, action: @escaping () -> Void) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(.primary)
                // A fixed circle: the glyph keeps its size, the Large Content Viewer shows it big.
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(width: size.points, height: size.points)
                .surface(.fill, in: Circle())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(title)
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("round.icon")
    }
}
