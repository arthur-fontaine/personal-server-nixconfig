import SwiftUI

/// One button of an `ActionRow`.
public struct Action: Identifiable {
    public let id: String
    let title: Text
    let emphasis: Emphasis
    let isBusy: Bool
    let perform: () -> Void

    public init(id: String, _ title: LocalizedStringKey, emphasis: Emphasis, isBusy: Bool = false, perform: @escaping () -> Void) {
        self.id = id
        self.title = Text(title)
        self.emphasis = emphasis
        self.isBusy = isBusy
        self.perform = perform
    }

    /// A label the app doesn't own (Hermes' answers), shown as sent.
    public init(id: String, verbatim title: String, emphasis: Emphasis, isBusy: Bool = false, perform: @escaping () -> Void) {
        self.id = id
        self.title = Text(verbatim: title)
        self.emphasis = emphasis
        self.isBusy = isBusy
        self.perform = perform
    }
}

public enum ActionRowError: Error, Equatable {
    /// HIG Buttons: "Don't assign the primary role to a button that performs a destructive action."
    case destructivePrimary
    /// HIG Buttons: one prominent button per view.
    case secondPrimary
    /// The primary slot holds a primary action.
    case notPrimary
    case empty
}

/// 1–3 buttons and an optional "…" menu for more answers (design-rules 5.3, 6.1).
///
/// - One `.large` height for every button of a row; capsules side by side, rounded rectangles
///   concentric with the card when they stack (HIG Buttons: capsules in a row, rounded rectangles
///   in a stack).
/// - The primary is prominent and trailing in a row, first in a stack; it can't be destructive.
/// - Stacks when the labels don't fit on one line each, and always at accessibility sizes (3.4).
public struct ActionRow: View {
    let primary: Action?
    let others: [Action]
    let more: [Action]
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.containerCornerRadius) private var containerRadius
    @Environment(\.containerInset) private var containerInset

    public init(primary: Action?, others: [Action] = [], more: [Action] = []) {
        do {
            try Self.validate(primary: primary, others: others, more: more)
        } catch {
            preconditionFailure("ActionRow: \(error)")
        }
        self.primary = primary
        self.others = others
        self.more = more
    }

    /// The rules `init` enforces, testable without trapping.
    nonisolated public static func validate(primary: Action?, others: [Action], more: [Action]) throws(ActionRowError) {
        if primary == nil, others.isEmpty, more.isEmpty { throw .empty }
        switch primary?.emphasis {
        case .destructive?: throw .destructivePrimary
        case .secondary?: throw .notPrimary
        case .primary?, nil: break
        }
        if (others + more).contains(where: { $0.emphasis == .primary }) { throw .secondPrimary }
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                row
                stacked
            }
        }
    }

    private var row: some View {
        HStack(spacing: Spacing.s.points) {
            if !more.isEmpty { moreMenu(lines: 1) }
            HStack(spacing: Spacing.s.points) {
                ForEach(others) { button($0, lines: 1) }
                if let primary { button(primary, lines: 1) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { reportedHeight = $0 }
        }
        .buttonBorderShape(.capsule)
        .preference(key: ControlHeightKey.self, value: reportedHeight)
    }

    @State private var reportedHeight: CGFloat = Metric.largeControl

    private var stacked: some View {
        VStack(spacing: Spacing.s.points) {
            if let primary { button(primary, lines: nil) }
            ForEach(others) { button($0, lines: nil) }
            if !more.isEmpty { moreMenu(lines: nil) }
        }
        // Concentric with the card: its corner minus the inset; a fixed shape out of a card.
        .buttonBorderShape(.roundedRectangle(radius: max(containerRadius - containerInset, Radius.blockMinimum)))
    }

    @ViewBuilder private func button(_ a: Action, lines: Int?) -> some View {
        let label = HStack(spacing: Spacing.xs.points) {
            // Small, so the busy button keeps the row's height (5.3).
            if a.isBusy { ProgressView().controlSize(.small).tint(a.emphasis == .primary ? AnyShapeStyle(OnAccentStyle()) : AnyShapeStyle(Color(uiColor: .label))) }
            a.title.lineLimit(lines).fixedSize(horizontal: lines == 1, vertical: lines == nil)
        }
        .frame(maxWidth: .infinity)

        // The identifier on the button itself, so tests measure the button, never its label.
        switch a.emphasis {
        case .primary:
            Button(action: a.perform) { label.foregroundStyle(OnAccentStyle()) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("action.\(a.id)")
        case .secondary:
            // The label colour itself: `.primary` would resolve against the grey tint.
            Button(action: a.perform) { label.foregroundStyle(Color(uiColor: .label)) }
                .buttonStyle(.bordered)
                .tint(.gray)
                .controlSize(.large)
                .accessibilityIdentifier("action.\(a.id)")
        case .destructive:
            // HIG alert (reference/metrics.md): red label on the neutral fill, not a red wash.
            Button(role: .destructive, action: a.perform) { label.foregroundStyle(.red) }
                .buttonStyle(.bordered)
                .tint(.gray)
                .controlSize(.large)
                .accessibilityIdentifier("action.\(a.id)")
        }
    }

    /// "…": in a row, the system's bordered circle as tall as the row (design-rules 10.1);
    /// stacked, a full-width "More Answers".
    @ViewBuilder private func moreMenu(lines: Int?) -> some View {
        let menu = Menu {
            ForEach(more) { a in
                Button(role: a.emphasis == .destructive ? .destructive : nil, action: a.perform) { a.title }
            }
        } label: {
            if lines == nil {
                Text("More Answers").frame(maxWidth: .infinity).foregroundStyle(Color(uiColor: .label))
            } else {
                // The system's circle around a square label: its fill is Deny's, its size the row's.
                let label = Metric.squareLargeButtonLabel(rowHeight: reportedHeight)
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color(uiColor: .label))
                    .frame(width: label.width, height: label.height)
            }
        }
        .accessibilityLabel(Text("More Answers"))
        .accessibilityIdentifier("action.more")
        if lines == nil {
            menu.menuStyle(.button).buttonStyle(.bordered).tint(.gray).controlSize(.large)
        } else {
            menu.menuStyle(.button).buttonStyle(.bordered).buttonBorderShape(.circle).tint(.gray).controlSize(.large)
        }
    }
}

/// Dims a hand-drawn control while pressed, as the system's bordered buttons do.
struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? Fade.pressed : 1)
    }
}

struct ControlHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension EnvironmentValues {
    /// Set by a card for what it holds: concentric radii are computed from these.
    @Entry var containerCornerRadius: CGFloat = 0
    @Entry var containerInset: CGFloat = 0
}
