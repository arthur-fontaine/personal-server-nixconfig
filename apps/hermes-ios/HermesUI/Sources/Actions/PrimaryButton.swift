import SwiftUI

/// The one prominent action of a screen (HIG Buttons: "use a button that has a prominent visual
/// style for the most likely action"): `.borderedProminent` at `.large`, the pet's fill with its
/// label (15.1), a progress indicator while it works, never destructive.
public struct PrimaryButton: View {
    let title: Text
    let systemImage: String?
    let isBusy: Bool
    let fullWidth: Bool
    let action: () -> Void

    /// `fullWidth`: a screen's main action at its foot (HIG Buttons: "Prefer buttons that span the
    /// width of the screen for primary actions").
    public init(_ title: LocalizedStringKey, systemImage: String? = nil, isBusy: Bool = false, fullWidth: Bool = false,
                action: @escaping () -> Void) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.isBusy = isBusy
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs.points) {
                if isBusy {
                    ProgressView().controlSize(.small).tint(OnAccentStyle())
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                title
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(OnAccentStyle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .wrappingButtonShape()
        .accentFillTint()
        .disabled(isBusy)
    }
}

extension View {
    /// A capsule while the label is one line; at accessibility sizes, where it wraps, a rounded
    /// rectangle whose corner is the one-line capsule's (as the owner's bubble), so a long label
    /// never makes an oval (design-rules 5.3).
    func wrappingButtonShape() -> some View { modifier(WrappingButtonShape()) }
}

struct WrappingButtonShape: ViewModifier {
    @Environment(\.dynamicTypeSize) private var size
    func body(content: Content) -> some View {
        content.buttonBorderShape(size.isAccessibilitySize ? .roundedRectangle(radius: Radius.field) : .capsule)
    }
}

/// A secondary action beside or under a primary one: `.bordered` on the neutral fill.
public struct SecondaryButton: View {
    let title: Text
    let systemImage: String?
    let fullWidth: Bool
    let action: () -> Void

    public init(_ title: LocalizedStringKey, systemImage: String? = nil, fullWidth: Bool = false, action: @escaping () -> Void) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs.points) {
                if let systemImage { Image(systemName: systemImage) }
                title
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(Color(uiColor: .label))
        }
            .buttonStyle(.bordered)
            .tint(.gray)
            .controlSize(.large)
            .wrappingButtonShape()
    }
}
