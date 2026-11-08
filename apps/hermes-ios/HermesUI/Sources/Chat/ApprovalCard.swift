import SwiftUI

/// Hermes asks (design-rules 6.1): a content-layer card in the transcript, the question as a
/// `.headline`, the raw command behind *Show Command*, then the answers. The card's corner follows
/// the measured height of its buttons, so it stays concentric with them at every text size.
public struct ApprovalCard: View {
    let question: String
    let command: String?
    let primary: Action?
    let others: [Action]
    let more: [Action]
    @State private var showCommand = false
    @State private var controlHeight = Metric.largeControl

    public init(question: String, command: String?, primary: Action?, others: [Action] = [], more: [Action] = []) {
        self.question = question
        self.command = command
        self.primary = primary
        self.others = others
        self.more = more
    }

    public var body: some View {
        CardSurface(surface: .grouped, inset: Block.card, innerControlHeight: controlHeight) {
            // The disclosure row carries its own air inside its 44-pt row (≈ 12 pt each side), so
            // nothing more around it: the visible gaps then match the card's padding (≈ 24 / 20).
            // Without a command, the card's padding between question and answers.
            VStack(alignment: .leading, spacing: command == nil ? Block.card.points : 0) {
                Text(verbatim: question)
                    .textRole(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let command {
                    DisclosureGroup(isExpanded: $showCommand) {
                        CodeBlock(command, wrapping: true)
                            .padding(.top, Spacing.xs.points)
                            .padding(.bottom, Rhythm.blocks.spacing.points)
                    } label: {
                        Text("Show Command").textRole(.body)
                            .multilineTextAlignment(.leading)
                            // The row is a control: at least the hit target tall, all of it tappable.
                            .frame(maxWidth: .infinity, minHeight: Metric.hitTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    // A secondary control: the label colour, the accent stays Allow Once's.
                    .tint(.primary)
                    .accessibilityIdentifier("approval.command")
                }
                ActionRow(primary: primary, others: others, more: more)
                    .onPreferenceChange(ControlHeightKey.self) { h in
                        if h > 0 { controlHeight = h }
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.approval")
    }
}

/// A file in the conversation: its symbol in a circle, name, detail, and a trailing hint.
/// Concentric: the card's corner is its inset plus the circle's radius.
public struct FileCard: View {
    let symbol: String
    let title: String
    let detail: Text
    let trailingSymbol: String?
    let action: () -> Void

    public init(symbol: String, title: String, detail: Text, trailingSymbol: String?, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.trailingSymbol = trailingSymbol
        self.action = action
    }

    public var body: some View {
        Button(action: action) { card }
            .buttonStyle(.plain)
            .frame(maxWidth: Metric.fileCardMaxWidth, alignment: .leading)
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    /// At accessibility sizes the card stacks (HIG Typography: "consider using a stacked layout"):
    /// the badge and the trailing glyph on one line, the name across the full width below.
    private var card: some View {
        CardSurface(surface: .grouped, inset: .s, innerControlHeight: Metric.fileSymbol) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.xs.points) {
                    HStack { badge; Spacer(minLength: Spacing.xs.points); trailing }
                    texts(nameLines: Self.stackedNameLines)
                }
            } else {
                HStack(spacing: Spacing.s.points) {
                    badge
                    texts(nameLines: 1)
                    Spacer(minLength: Spacing.xs.points)
                    trailing
                }
            }
        }
    }

    static let stackedNameLines = 3

    private var badge: some View {
        Image(systemName: symbol)
            .tone(.accent)
            // The badge is a fixed circle: its glyph keeps its size (10.1, 3.4).
            .dynamicTypeSize(...DynamicTypeSize.large)
            .frame(width: Metric.fileSymbol, height: Metric.fileSymbol)
            .surface(.elevated, in: Circle())
            .accessibilityHidden(true)
            .accessibilityIdentifier("round.filesymbol")
    }

    @ViewBuilder private var trailing: some View {
        if let trailingSymbol {
            // The same scale as the badge's glyph.
            Image(systemName: trailingSymbol).tone(.secondary)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .accessibilityHidden(true)
        }
    }

    /// A file name is an identifier: it may break anywhere (no hyphen), up to `nameLines` lines,
    /// then truncates in the middle, keeping its extension.
    private func texts(nameLines: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs.points) {
            Text(verbatim: nameLines > 1 ? Self.breakableAnywhere(title) : title)
                .textRole(.subheadline).fontWeight(.semibold)
                .lineLimit(nameLines).truncationMode(.middle)
                .accessibilityLabel(Text(verbatim: title))
            detail.textRole(.caption).tone(.secondary)
        }
    }

    /// Zero-width spaces between characters: line breaks without hyphenation.
    static func breakableAnywhere(_ s: String) -> String {
        s.map(String.init).joined(separator: "\u{200B}")
    }
}
