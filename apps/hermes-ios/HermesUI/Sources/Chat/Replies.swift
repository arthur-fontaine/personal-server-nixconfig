import SwiftUI
import UIKit

/// Above a message that replies to another (design-rules 16.1, as Messages' and Telegram's reply
/// context): a thin leading bar in the pet's colour, the original's author in footnote semibold
/// and its first line in secondary, one line. Content layer: no glass, no stroke. A button that
/// shows the original; when the original is gone it says so and does nothing.
public struct ReplyContext: View {
    public enum Kind {
        case original(author: Text, excerpt: Text)
        case loading
        case deleted
    }

    let kind: Kind
    let speaker: Speaker
    let label: Text
    let action: () -> Void

    /// `speaker`: who wrote the reply — above the owner's bubble the context keeps to the bubble's
    /// side and width (its leading room, its corner's inset). `label`: what VoiceOver reads
    /// ("Reply to Hermes: …", 16.4).
    public init(_ kind: Kind, above speaker: Speaker, accessibilityLabel label: Text, action: @escaping () -> Void) {
        self.kind = kind
        self.speaker = speaker
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs.points) {
                Capsule().fill(AccentFillStyle()).frame(width: Metric.replyBar)
                VStack(alignment: .leading, spacing: 0) {
                    switch kind {
                    case .original(let author, let excerpt):
                        author.textRole(.footnote).fontWeight(.semibold).tone(.primary)
                        excerpt.textRole(.footnote).tone(.secondary)
                    case .loading:
                        Text(verbatim: "Hermes").textRole(.footnote).fontWeight(.semibold)
                        Text(verbatim: "…").textRole(.footnote)
                    case .deleted:
                        Text("Message deleted").textRole(.footnote).italic().tone(.secondary)
                    }
                }
                .lineLimit(1)
                .redacted(reason: isLoading ? .placeholder : [])
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(BubbleSide(isOwner: speaker == .owner))
        .disabled(isGone || isLoading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(isGone ? Text(verbatim: "") : Text("Shows the original message"))
    }

    private var isGone: Bool { if case .deleted = kind { true } else { false } }
    private var isLoading: Bool { if case .loading = kind { true } else { false } }
}

public extension View {
    /// The original a reply jumped to, lit for a moment with the pet's light tint (16.2). With
    /// Reduce Motion it appears and goes without a fade.
    func replyHighlight(_ isOn: Bool) -> some View { modifier(ReplyHighlight(isOn: isOn)) }

    /// Swipe toward the trailing edge to reply (16.3, as Messages and Telegram): the message
    /// follows the finger, a reply arrow appears behind it, a haptic marks the threshold. A pan
    /// that only begins when mostly horizontal, so the transcript still scrolls. VoiceOver and
    /// Switch Control get a "Reply" action instead.
    func swipeToReply(_ action: @escaping () -> Void) -> some View { modifier(SwipeToReply(action: action)) }
}

/// Above the owner's bubble: within its width (its leading room) and its text's inset, so the bar
/// lines up with the bubble's text.
struct BubbleSide: ViewModifier {
    let isOwner: Bool
    func body(content: Content) -> some View {
        if isOwner {
            content.inset(.horizontal, Bubble.horizontal).padding(.leading, Metric.bubbleLeadingRoom)
        } else {
            content
        }
    }
}

struct ReplyHighlight: ViewModifier {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // Only while lit: reaching past the row, it would widen its frame at rest.
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: Radius.blockMinimum, style: .continuous)
                        .fill(AccentTintStyle())
                        // Past the message's edges, so the text doesn't touch the tint's.
                        .padding(-Spacing.xs.points)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: Self.fade), value: isOn)
    }

    static let fade = 0.6
}

struct SwipeToReply: ViewModifier {
    let action: () -> Void
    @State private var offset: CGFloat = 0
    @Environment(\.layoutDirection) private var direction

    func body(content: Content) -> some View {
        let progress = min(offset / Metric.replySwipe, 1)
        content
            .offset(x: direction == .rightToLeft ? -offset : offset)
            // Only during a swipe: at rest the arrow would widen the row's frame past its edge.
            .background(alignment: .leading) {
                if offset > 0 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .tone(.secondary)
                        .scaleEffect(progress)
                        .opacity(progress)
                        .offset(x: progress * Metric.hitTarget - Metric.hitTarget)
                        .accessibilityHidden(true)
                }
            }
            .gesture(ReplyPan(direction: direction) { dx in
                offset = max(0, dx)
            } ended: { dx in
                if dx >= Metric.replySwipe { action() }
                withAnimation(.snappy) { offset = 0 }
            })
            .sensoryFeedback(.impact(weight: .light), trigger: offset >= Metric.replySwipe) { _, crossed in crossed }
            .accessibilityAction(named: Text("Reply"), action)
    }
}

/// The swipe's pan: begins only toward the trailing edge and mostly horizontally, so a vertical
/// drag stays the scroll view's.
struct ReplyPan: UIGestureRecognizerRepresentable {
    let direction: LayoutDirection
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(direction: direction) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let sign: CGFloat = direction == .rightToLeft ? -1 : 1
        let dx = pan.translation(in: pan.view).x * sign
        switch pan.state {
        case .changed: changed(dx)
        case .ended, .cancelled, .failed: ended(pan.state == .ended ? dx : 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let direction: LayoutDirection
        init(direction: LayoutDirection) { self.direction = direction }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            let toward = direction == .rightToLeft ? -v.x : v.x
            return toward > 0 && abs(v.x) > abs(v.y) * 2
        }

        // The scroll view's pan sees the touch first; both may run, ours only once horizontal.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// A message's text to select any part of (its menu's "Select Text"): the transcript's long press
/// opens the message's menu instead, as Messages'.
public struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    public init(_ text: String) { self.text = text }

    public var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: text)
                    .textRole(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scenePaddingHorizontal()
                    .inset(.vertical, .m)
            }
            .navigationTitle(Text("Select Text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { ConfirmButton("Done") { dismiss() } } }
        }
    }
}
