import SwiftUI

// Chrome/ is the functional layer: the only folder where DesignCheck allows Liquid Glass
// (design-rules 5.5, HIG Materials: "Don't use Liquid Glass in the content layer").

/// What the composer's trailing button does.
public enum ComposerAction: Sendable {
    case send(enabled: Bool)
    case sending
    /// Hermes is writing: Stop replaces Send.
    case stop
}

/// The composer, as Messages': a "+" glass circle and a glass field with the send button inside
/// its trailing end (reference/metrics.md). Both 44 pt (hit target); the send button is a 36-pt
/// accent circle 4 pt inside the field's corner, concentric with it (22 − 4 = 18), with a 44-pt
/// hit area. One glass container, so the two shapes blend as the system's do.
public struct ComposerBar<MenuItems: View>: View {
    @Binding var text: String
    let placeholder: Text
    let action: ComposerAction
    let focus: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onStop: () -> Void
    let menuItems: MenuItems

    public init(text: Binding<String>, placeholder: Text, action: ComposerAction, focus: FocusState<Bool>.Binding,
                onSend: @escaping () -> Void, onStop: @escaping () -> Void, @ViewBuilder menu: () -> MenuItems) {
        _text = text
        self.placeholder = placeholder
        self.action = action
        self.focus = focus
        self.onSend = onSend
        self.onStop = onStop
        menuItems = menu()
    }

    public var body: some View {
        let fieldShape = RoundedRectangle(cornerRadius: Radius.composerField, style: .continuous)
        GlassEffectContainer(spacing: Spacing.s.points) {
            HStack(alignment: .bottom, spacing: Spacing.s.points) {
                Menu { menuItems } label: {
                    Image(systemName: "plus")
                        .textRole(.body).imageScale(.large)
                        .tone(.primary)
                        // Bar glyphs keep their size and show in the Large Content Viewer instead,
                        // as the system's bars do: the circle stays a 44-pt circle at AX sizes.
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .frame(width: Metric.composerControl, height: Metric.composerControl)
                        .contentShape(Circle())
                }
                .glassEffect(.regular.interactive(), in: Circle())
                // Bar controls are monochrome (HIG Toolbars); the accent is Send's.
                .tint(.primary)
                .accessibilityLabel(Text("Attach"))
                .accessibilityShowsLargeContentViewer()
                .accessibilityIdentifier("composer.attach")

                HStack(alignment: .bottom, spacing: 0) {
                    TextField(text: $text, axis: .vertical) { placeholder }
                        .textRole(.body)
                        .lineLimit(1...8)
                        .focused(focus)
                        .inset(.vertical, .xs)
                        .frame(minHeight: Metric.composerControl)
                        .inset(.leading, .m)
                        .accessibilityIdentifier("composer.field")
                    trailingButton
                }
                .contentShape(fieldShape)
                .glassEffect(.regular.interactive(), in: fieldShape)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("composer.capsule")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer")
    }

    @ViewBuilder private var trailingButton: some View {
        let isStop = { if case .stop = action { true } else { false } }()
        let enabled: Bool = switch action {
        case .send(let e): e
        case .sending: false
        case .stop: true
        }
        Button(action: isStop ? onStop : onSend) {
            Image(systemName: isStop ? "stop.fill" : (action.isSending ? "ellipsis" : "arrow.up"))
                .textRole(.body).fontWeight(.semibold)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .foregroundStyle(enabled ? AnyShapeStyle(OnAccentStyle()) : AnyShapeStyle(.tertiary))
                .frame(width: Metric.sendButton, height: Metric.sendButton)
                .background(enabled ? AnyShapeStyle(.tint) : Surface.fill.style, in: Circle())
                .contentTransition(.symbolEffect(.replace))
                // The hit area is the full 44-pt square at the field's corner.
                .frame(width: Metric.composerControl, height: Metric.composerControl)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(isStop ? Text("Stop") : Text("Send"))
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier(isStop ? "composer.stop" : "composer.send")
    }
}

extension ComposerAction {
    var isSending: Bool { if case .sending = self { true } else { false } }
}

/// A short confirmation at the top of the screen, floating (functional layer).
public struct Toast: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(verbatim: text)
            .textRole(.subheadline)
            .inset(.horizontal, .m)
            .inset(.vertical, .s)
            .glassEffect(.regular, in: Capsule())
            .inset(.top, .xs)
    }
}

/// A floating button above the composer ("↓ Latest").
public struct FloatingButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    public init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        symbol = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) { Label(title, systemImage: symbol).textRole(.subheadline) }
            .buttonStyle(.glass)
            .controlSize(.large)
    }
}

/// A file waiting in the composer: glass, as the composer it sits on.
public struct AttachmentChip: View {
    let symbol: String
    let name: String
    let detail: String
    let onRemove: () -> Void

    public init(symbol: String, name: String, detail: String, onRemove: @escaping () -> Void) {
        self.symbol = symbol
        self.name = name
        self.detail = detail
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: Spacing.xs.points) {
            Image(systemName: symbol).tone(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name).textRole(.caption).fontWeight(.semibold)
                Text(verbatim: detail).textRole(.caption).tone(.secondary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").tone(.secondary)
                    .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(name)"))
        }
        .inset(.leading, .s)
        .glassEffect(.regular, in: Capsule())
    }
}

/// An upload in progress, above the composer.
public struct UploadBar: View {
    let title: Text
    let fraction: Double

    public init(title: Text, fraction: Double) {
        self.title = title
        self.fraction = fraction
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.composerField, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.xxs.points) {
            title.textRole(.caption)
            ProgressView(value: fraction)
        }
        .inset(.horizontal, .m)
        .inset(.vertical, .xs)
        .glassEffect(.regular, in: shape)
    }
}

/// A toolbar button: a symbol (or the pet) in the system's bar item, monochrome — the accent is
/// for primary actions, not for bar items (HIG Toolbars, "Reduce the use of … tinted controls";
/// design-rules 4.2).
public struct BarButton<Icon: View>: View {
    let title: Text
    let action: () -> Void
    let icon: Icon

    public init(_ title: Text, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.action = action
        self.icon = icon()
    }

    public var body: some View {
        // The icon alone, labelled for VoiceOver: a custom icon inside a `Label` is resized by
        // the bar.
        Button(action: action) { icon }
            .accessibilityLabel(title)
            .tint(.primary)
    }
}

public extension View {
    /// Bars and their menus stay monochrome (HIG Toolbars): for a sheet's toolbar items and a
    /// title menu's content, whose system controls otherwise take the app's accent.
    func barMonochrome() -> some View { tint(.primary) }
}

/// A toolbar item whose tap does one thing and whose long press opens a menu
/// (`Menu(primaryAction:)`, the system's pattern; a context menu on a bar item is a cramped
/// preview). Monochrome, labelled for VoiceOver, the icon alone in the bar's circle.
public struct BarMenuButton<Icon: View, Items: View>: View {
    let title: Text
    let primaryAction: () -> Void
    let icon: Icon
    let items: Items

    public init(_ title: Text, primaryAction: @escaping () -> Void, @ViewBuilder icon: () -> Icon, @ViewBuilder menu: () -> Items) {
        self.title = title
        self.primaryAction = primaryAction
        self.icon = icon()
        items = menu()
    }

    public var body: some View {
        Menu(content: { items }, label: { icon }, primaryAction: primaryAction)
            .accessibilityLabel(title)
            .tint(.primary)
    }
}

public extension BarButton where Icon == Image {
    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.init(Text(title), action: action) { Image(systemName: systemImage) }
    }
}
