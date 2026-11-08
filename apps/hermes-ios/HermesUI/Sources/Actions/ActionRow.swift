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
            if a.isBusy { ProgressView() }
            a.title.lineLimit(lines).fixedSize(horizontal: lines == 1, vertical: lines == nil)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("action.\(a.id)")

        switch a.emphasis {
        case .primary:
            Button(action: a.perform) { label.foregroundStyle(OnAccentStyle()) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .secondary:
            Button(action: a.perform) { label.foregroundStyle(.primary) }
                .buttonStyle(.bordered)
                .tint(.gray)
                .controlSize(.large)
        case .destructive:
            // HIG alert (reference/metrics.md): red label on the neutral fill, not a red wash.
            Button(role: .destructive, action: a.perform) { label.foregroundStyle(.red) }
                .buttonStyle(.bordered)
                .tint(.gray)
                .controlSize(.large)
        }
    }

    /// "…": in a row, a circle of the row's height (design-rules 10.1) — its width is set equal to
    /// the measured height, so it is round by construction; stacked, a full-width "More Answers".
    @ViewBuilder private func moreMenu(lines: Int?) -> some View {
        let menu = Menu {
            ForEach(more) { a in
                Button(role: a.emphasis == .destructive ? .destructive : nil, action: a.perform) { a.title }
            }
        } label: {
            if lines == nil {
                Text("More Answers").frame(maxWidth: .infinity).foregroundStyle(.primary)
            } else {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.primary)
                    .frame(width: reportedHeight, height: reportedHeight)
                    .background(Surface.fill.style, in: Circle())
                    .contentShape(Circle())
            }
        }
        .accessibilityLabel(Text("More Answers"))
        .accessibilityIdentifier("action.more")
        if lines == nil {
            menu.menuStyle(.button).buttonStyle(.bordered).tint(.gray).controlSize(.large)
        } else {
            menu.menuStyle(.button).buttonStyle(PressFade())
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
