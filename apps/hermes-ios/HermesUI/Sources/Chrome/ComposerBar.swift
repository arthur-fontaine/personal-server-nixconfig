import SwiftUI
import UIKit

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
                .background(enabled ? AnyShapeStyle(AccentFillStyle()) : Surface.fill.style, in: Circle())
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
            // Not a primary action: monochrome, as the bar's controls (HIG Color, Liquid Glass color).
            .tint(.primary)
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
        // A capsule at its usual size, the composer's corner once it grows (a capsule taller than
        // a line pinches its text: 5.1); the name is an identifier, so it truncates in the middle
        // rather than wrapping or hyphenating.
        let shape = RoundedRectangle(cornerRadius: Radius.composerField, style: .continuous)
        HStack(alignment: .top, spacing: Spacing.xs.points) {
            Image(systemName: symbol).tone(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(minHeight: Metric.hitTarget)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name).textRole(.caption).fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: detail).textRole(.caption).tone(.secondary)
            }
            .inset(.vertical, .xs)
            // The × keeps its size, in a 44-pt square at the chip's top-trailing corner: its centre
            // is the corner's centre (22, 22), concentric with the chip (5.1), inside it (5.2).
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").tone(.secondary)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove \(name)"))
        }
        .inset(.leading, .s)
        .glassEffect(.regular, in: shape)
    }
}

/// The message being replied to, above the composer (design-rules 16.3): the pet-colour bar, its
/// author and first line, and × to cancel. Glass, as the composer it belongs to; the AttachmentChip's
/// shape and its 44-pt ×.
public struct ReplyChip: View {
    let author: Text
    let excerpt: Text
    let label: Text
    let onClose: () -> Void

    public init(author: Text, excerpt: Text, accessibilityLabel label: Text, onClose: @escaping () -> Void) {
        self.author = author
        self.excerpt = excerpt
        self.label = label
        self.onClose = onClose
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.composerField, style: .continuous)
        HStack(spacing: Spacing.xs.points) {
            Capsule().fill(AccentFillStyle()).frame(width: Metric.replyBar).inset(.vertical, .xs)
            VStack(alignment: .leading, spacing: 0) {
                author.textRole(.caption).fontWeight(.semibold)
                excerpt.textRole(.caption).tone(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").tone(.secondary)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .frame(width: Metric.hitTarget, height: Metric.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Reply"))
        }
        .fixedSize(horizontal: false, vertical: true)
        .inset(.leading, .s)
        .glassEffect(.regular, in: shape)
    }
}

/// An upload in progress, above the composer. Takes a Foundation `Progress`, not a number
/// (design-rules 9.2).
public struct UploadBar: View {
    let title: Text
    let progress: Progress

    public init(title: Text, progress: Progress) {
        self.title = title
        self.progress = progress
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.composerField, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.xxs.points) {
            title.textRole(.caption)
            // The bar alone: `ProgressView(Progress)` adds its own "42% completed" lines.
            ProgressView(value: progress.fractionCompleted).progressViewStyle(PetProgress())
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

/// A bar item whose tap does one thing and whose long press opens a menu anchored to the item,
/// as Safari's Back button: UIKit's `UIButton` with a primary action and a `menu`
/// (`showsMenuAsPrimaryAction = false`), which shows the menu from the button itself — no lifted
/// preview, no dimming. (SwiftUI's `Menu(primaryAction:)` as a toolbar item doesn't respond to a
/// tap on iOS 26.2; a `.contextMenu` lifts the label out of the bar.)
public struct BarMenuButton: View {
    let image: UIImage
    let title: String
    let primaryAction: () -> Void
    let menuTitle: String
    let items: [BarMenuItem]

    public init(image: UIImage, title: String, primaryAction: @escaping () -> Void, menuTitle: String, items: [BarMenuItem]) {
        self.image = image
        self.title = title
        self.primaryAction = primaryAction
        self.menuTitle = menuTitle
        self.items = items
    }

    public var body: some View {
        BarMenuUIButton(image: image, title: title, primaryAction: primaryAction, menuTitle: menuTitle, items: items)
    }
}

struct BarMenuUIButton: UIViewRepresentable {
    let image: UIImage
    let title: String
    let primaryAction: () -> Void
    let menuTitle: String
    let items: [BarMenuItem]

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        update(button)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) { update(button) }

    private func update(_ button: UIButton) {
        var config = UIButton.Configuration.plain()
        config.image = image.withRenderingMode(.alwaysOriginal)
        config.contentInsets = .zero
        button.configuration = config
        button.removeTarget(nil, action: nil, for: .allEvents)
        let action = primaryAction
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.menu = UIMenu(title: menuTitle, options: .displayInline, children: items.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.systemImage)) { _ in item.action() }
        })
        button.accessibilityLabel = title
    }

    /// The image's width, the bar item's height: the bar pads it sideways into a 36-pt circle.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: image.size.width, height: Metric.barItem)
    }
}

public struct BarMenuItem {
    let title: String
    let systemImage: String
    let action: () -> Void

    public init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }
}

public extension BarButton where Icon == Image {
    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.init(Text(title), action: action) { Image(systemName: systemImage) }
    }
}

/// A sheet's confirming action in its toolbar (Create, Unlock, Hatch): the system's confirm role,
/// which the bar draws prominent (HIG Toolbars: "use the prominent style for key actions such as
/// Done"), filled with the pet's colour and its black or white label (15.1).
public struct ConfirmButton: View {
    let title: Text
    let action: () -> Void
    @Environment(\.accentFill) private var fill
    @Environment(\.onAccent) private var label

    public init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = Text(title)
        self.action = action
    }

    public var body: some View {
        Button(role: .confirm, action: action) { title.foregroundStyle(label) }
            .buttonStyle(.glassProminent)
            .tint(fill)
    }
}

/// A sheet's dismissing action (× or Cancel): the system's role, monochrome (HIG Toolbars: prefer
/// monochrome items; 15.2: no accent glyph).
public struct DismissButton: View {
    public enum Kind: Sendable { case close, cancel }
    let kind: Kind
    let action: () -> Void

    public init(_ kind: Kind, action: @escaping () -> Void) {
        self.kind = kind
        self.action = action
    }

    public var body: some View {
        Button(role: kind == .close ? .close : .cancel, action: action).barMonochrome()
    }
}

public extension View {
    /// A menu picker in a list row: its value in secondary, as Settings' (15.2: no accent text).
    func valuePicker() -> some View { tint(.secondary) }
}
