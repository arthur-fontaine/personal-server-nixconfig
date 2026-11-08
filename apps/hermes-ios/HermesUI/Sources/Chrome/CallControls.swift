import SwiftUI

/// A call control as the Phone app's (functional layer: glass): a round button of one size, its
/// label under it; a toggle fills white with a dark glyph while on, End is the system red.
public struct CallButton: View {
    public enum Kind: Sendable {
        case toggle(isOn: Bool)
        case end
    }

    let title: Text
    let systemImage: String
    let kind: Kind
    let action: () -> Void

    public init(_ title: Text, systemImage: String, kind: Kind, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Spacing.xs.points) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .textRole(.headline).imageScale(.large)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .foregroundStyle(glyph)
                    .frame(width: Metric.callButton, height: Metric.callButton)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(glass, in: Circle())
            .accessibilityLabel(title)
            .accessibilityShowsLargeContentViewer()
            title.textRole(.caption).tone(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        // One fixed column per button, as the Phone app's grid: centres stay 96 pt apart whatever
        // the label's language or size; a long label wraps inside its column (design-rules 2.4).
        .frame(width: Metric.callColumn, alignment: .top)
    }

    private var isOn: Bool { if case .toggle(true) = kind { true } else { false } }
    private var isEnd: Bool { if case .end = kind { true } else { false } }

    private var glyph: Color { isOn ? .black : .white }

    private var glass: Glass {
        if isEnd { return .regular.tint(.red).interactive() }
        return isOn ? .regular.tint(.white).interactive() : .regular.interactive()
    }
}

/// The row of call controls, glass shapes blending as the system's.
public struct CallControls<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        GlassEffectContainer(spacing: Spacing.xl.points) {
            HStack(alignment: .top, spacing: 0) { content }
        }
    }
}
