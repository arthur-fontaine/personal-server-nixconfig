import SwiftUI

/// The conversation's column (design-rules 2.1, 2.2, 9.3): the one leading edge of the chat — the
/// system's layout margin — and a readable width on wide screens. The transcript and the composer
/// both sit in one, so text, code, cards, bubbles and the composer share their edges.
public struct ChatColumn<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .frame(maxWidth: Metric.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .scenePadding(.horizontal)
            // No container corner to be concentric with inside the column: blocks use their minimum.
            .containerShape(Rectangle())
    }
}

/// Who wrote a transcript item: the vertical rhythm follows it (design-rules 2.4).
public enum Speaker: Equatable, Sendable {
    case hermes, owner, system
}

/// One item of the transcript, spaced from the previous one by the rhythm: a turn apart when the
/// speaker changes, closer within a turn. The first item has no gap.
public struct TranscriptRow<Content: View>: View {
    let speaker: Speaker
    let previous: Speaker?
    let content: Content

    public init(_ speaker: Speaker, after previous: Speaker?, @ViewBuilder content: () -> Content) {
        self.speaker = speaker
        self.previous = previous
        self.content = content()
    }

    static func gap(_ speaker: Speaker, after previous: Speaker?) -> Spacing? {
        guard let previous else { return nil }
        if previous != speaker { return Rhythm.turn.spacing }
        return (speaker == .owner ? Rhythm.bubbles : Rhythm.blocks).spacing
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: speaker == .owner ? .trailing : .leading)
            .padding(.top, Self.gap(speaker, after: previous)?.points ?? 0)
    }
}

/// The scroll view's bottom, to scroll to. It is the gap between the last item and the composer,
/// so scrolling to it keeps that gap (a reply's block rhythm).
public struct ScrollAnchor: View {
    public init() {}
    public var body: some View { Color.clear.frame(height: Rhythm.blocks.spacing.points) }
}

/// The conversation's typography: every block of one message is `MessageBlocks`, spaced within a
/// turn.
public struct MessageBlocks<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.blocks.spacing.points) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hermes' prose: no bubble, `.body`, selectable (design-rules 3.1, brief "Chat").
public struct MessageText: View {
    let text: AttributedString
    public init(_ text: AttributedString) { self.text = text }
    public init(verbatim text: String) { self.text = AttributedString(text) }

    public var body: some View {
        Text(text)
            .textRole(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A block quote: secondary italic prose behind a quiet rule, as Mail quotes.
public struct QuoteBlock: View {
    let text: AttributedString
    public init(_ text: AttributedString) { self.text = text }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.s.points) {
            Capsule().fill(.tertiary).frame(width: Metric.quoteRule)
            Text(text).textRole(.body).italic().tone(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Code (design-rules 6.2): the grouped fill (elevated inside a card), a corner concentric with
/// its container or the block minimum, monospaced, scrolling sideways instead of wrapping; Copy is
/// in the context menu.
public struct CodeBlock: View {
    let code: String
    let wraps: Bool
    @Environment(\.containerCornerRadius) private var containerRadius
    @Environment(\.containerInset) private var containerInset

    /// `wrapping`: a command to be approved is read whole, so it wraps instead of scrolling.
    public init(_ code: String, wrapping: Bool = false) {
        self.code = code
        wraps = wrapping
    }

    public var body: some View {
        let nested = containerRadius > 0
        let radius = max(containerRadius - containerInset, Radius.blockMinimum)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if wraps {
                text.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) { text.fixedSize() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(nested ? .elevated : .grouped, in: shape)
        .contextMenu {
            Button { UIPasteboard.general.string = code } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        .geometryProbe(radius: radius, inset: Block.padding.points)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(wraps ? "approval.code" : "chat.code")
    }

    private var text: some View {
        Text(verbatim: code)
            .textRole(.code)
            .textSelection(.enabled)
            .inset(.all, Block.padding)
    }
}

/// The owner's message (reference/metrics.md, "What Hermes takes"): a neutral bubble, capsule at
/// one line, trailing, at least `bubbleLeadingRoom` from the leading edge. Neutral rather than the
/// accent, so the accent keeps meaning "act here" (design-rules 4.2).
public struct UserBubble: View {
    let text: String
    let state: State
    @ScaledMetric(relativeTo: .body) private var radius = Radius.bubble
    @ScaledMetric(relativeTo: .body) private var minHeight = Metric.oneLineBubble

    public enum State: Sendable { case sent, pending, failed }

    public init(_ text: String, state: State = .sent) {
        self.text = text
        self.state = state
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.xs.points) {
            if state == .failed {
                Image(systemName: "exclamationmark.circle.fill").tone(.destructive)
                    .accessibilityLabel(Text("Not Sent"))
            }
            Text(verbatim: text)
                .textRole(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .inset(.horizontal, Bubble.horizontal)
                .inset(.vertical, Bubble.vertical)
                .frame(minHeight: minHeight)
                .surface(.fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .opacity(state == .pending ? Fade.pending : 1)
                .geometryProbe(radius: radius, inset: Bubble.vertical.points)
                .accessibilityIdentifier("chat.bubble")
        }
        .padding(.leading, Metric.bubbleLeadingRoom)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

enum Fade {
    /// A message still on its way.
    static let pending = 0.6
    /// A hand-drawn control while pressed.
    static let pressed = 0.5
}

/// Hermes is writing: three dots, the only motion besides the text itself (design-rules 7.1).
public struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}

    public var body: some View {
        TimelineView(.animation(minimumInterval: 0.3, paused: reduceMotion)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: Spacing.xxs.points) {
                ForEach(0..<3) { i in
                    Circle().frame(width: Metric.typingDot, height: Metric.typingDot)
                        .opacity(i == phase ? 1 : 0.35)
                }
            }
            .tone(.secondary)
            // As tall as a line of text, so it doesn't shift the transcript when the text arrives.
            .frame(minHeight: Metric.bodyLine)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Hermes is writing"))
    }
}

/// A centred time between messages far apart (Messages-style).
public struct TimeLabel: View {
    let date: Date
    public init(_ date: Date) { self.date = date }

    public var body: some View {
        Text(date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute()
                            : .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
            .textRole(.footnote)
            .tone(.secondary)
            .frame(maxWidth: .infinity)
    }
}

/// The transcript's stack: no spacing of its own, `TranscriptRow`s carry the rhythm.
public struct TranscriptStack<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) { content }
            .inset(.top, .s)
    }
}
