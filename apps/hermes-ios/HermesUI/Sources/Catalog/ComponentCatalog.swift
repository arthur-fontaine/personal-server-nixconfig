import SwiftUI

/// One page per HermesUI component, every variant (design-rules 9.6). The app shows a page with
/// `-catalog <page>`; the screenshot tour renders each in light, dark and at AX5 for the critic.
public enum CatalogPage: String, CaseIterable, Sendable {
    case type, surfaces, actions, approval, chat, files, composer, accent
}

public struct ComponentCatalog: View {
    let page: CatalogPage
    @State private var text = ""
    @State private var typed = "Can you also check the photos backup?"
    @FocusState private var focus: Bool

    public init(page: CatalogPage) { self.page = page }

    public var body: some View {
        ScrollView {
            ChatColumn {
                VStack(alignment: .leading, spacing: Spacing.xl.points) {
                    content
                }
                .inset(.vertical, .m)
            }
        }
        .navigationTitle(Text(verbatim: "HermesUI · \(page.rawValue)"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .type:
            ForEach(TextRole.allCases, id: \.self) { role in
                section("TextRole.\(role)") {
                    Text(verbatim: role == .code ? "restic forget --keep-within 90d" : "The external disk was full.").textRole(role)
                }
            }
            section("Tone") {
                ForEach(Tone.allCases, id: \.self) { tone in Text(verbatim: "Tone.\(tone)").textRole(.body).tone(tone) }
            }
        case .surfaces:
            ForEach(Surface.allCases, id: \.self) { s in
                section("CardSurface(.\(s))") {
                    CardSurface(s) { Text(verbatim: "Separated by fill alone: no stroke, no shadow.").textRole(.body) }
                }
            }
            section("Spacing") {
                ForEach(Spacing.allCases, id: \.self) { sp in
                    HStack(spacing: Spacing.s.points) {
                        Text(verbatim: "\(sp)").textRole(.caption).tone(.secondary)
                        Capsule().fill(.tint).frame(width: sp.points, height: Spacing.xs.points)
                    }
                }
            }
        case .actions:
            section("Primary + destructive + more (row)") {
                ActionRow(primary: Action(id: "p", "Allow Once", emphasis: .primary) {},
                          others: [Action(id: "d", "Deny", emphasis: .destructive) {}],
                          more: [Action(id: "m1", "Allow for This Session", emphasis: .secondary) {}])
            }
            section("Two secondaries") {
                ActionRow(primary: nil, others: [Action(id: "a", verbatim: "Casa do Largo", emphasis: .secondary) {},
                                                 Action(id: "b", verbatim: "Alfama Patio", emphasis: .secondary) {}])
            }
            section("IconButton (.regular, .large)") {
                HStack(spacing: Spacing.s.points) {
                    IconButton("Copy", systemImage: "doc.on.doc") {}
                    IconButton("Share", systemImage: "square.and.arrow.up", size: .large) {}
                }
            }
            section("Busy") {
                ActionRow(primary: Action(id: "p", "Allow Once", emphasis: .primary, isBusy: true) {},
                          others: [Action(id: "d", "Deny", emphasis: .destructive) {}])
            }
            section("Long labels stack, primary first") {
                ActionRow(primary: Action(id: "p", verbatim: "Autoriser pour toute la session", emphasis: .primary) {},
                          others: [Action(id: "d", verbatim: "Refuser et expliquer pourquoi", emphasis: .destructive) {}])
            }
        case .approval:
            section("ApprovalCard") {
                ApprovalCard(question: "Delete backup snapshots older than 90 days to free about 212 GB on the external disk?",
                             command: "restic -r /Volumes/Backup/restic forget --keep-within 90d --prune",
                             primary: Action(id: "once", "Allow Once", emphasis: .primary) {},
                             others: [Action(id: "deny", "Deny", emphasis: .destructive) {}],
                             more: [Action(id: "session", "Allow for This Session", emphasis: .secondary) {},
                                    Action(id: "always", "Always Allow", emphasis: .secondary) {}])
            }
            section("ApprovalCard, no command, two answers") {
                ApprovalCard(question: "Book Casa do Largo for 3 nights from the 14th, €426 in total?", command: nil,
                             primary: Action(id: "yes", verbatim: "Book It", emphasis: .primary) {},
                             others: [Action(id: "no", verbatim: "Not Now", emphasis: .secondary) {}])
            }
        case .chat:
            section("UserBubble (sent, pending, failed)") {
                VStack(spacing: Rhythm.bubbles.spacing.points) {
                    UserBubble("Yes, go ahead")
                    UserBubble("What happened with the backup last night? It was supposed to run at 3.", state: .pending)
                    UserBubble("Remind me to call mum", state: .failed)
                }
            }
            section("MessageText + CodeBlock + QuoteBlock") {
                MessageBlocks {
                    MessageText(verbatim: "The external disk was full, so restic stopped before pruning:")
                    CodeBlock("Fatal: unable to save snapshot: no space left on device")
                    QuoteBlock(AttributedString("Keep the last 90 days, prune the rest."))
                }
            }
            section("PetAvatar (every size): a square box clipped by a circle") {
                HStack(alignment: .bottom, spacing: Spacing.m.points) {
                    ForEach([PetSize.toolbar, .row, .hero], id: \.self) { size in
                        PetAvatar(size) { Image(systemName: "bird.fill").resizable().scaledToFit().tone(.accent) }
                    }
                }
            }
            section("TypingIndicator, TimeLabel") {
                TypingIndicator()
                TimeLabel(.now)
            }
        case .files:
            section("FileCard") {
                FileCard(symbol: "film", title: "Saturday.mov", detail: Text(verbatim: "6.2 GB, on Gofile"), trailingSymbol: "arrow.up.right") {}
                FileCard(symbol: "doc.richtext", title: "Statements-2025.pdf", detail: Text(verbatim: "1.4 MB"), trailingSymbol: "arrow.down.circle") {}
            }
        case .composer:
            section("Empty (Send disabled)") { composer(.send(enabled: false), text: $text) }
            section("Typed (Send)") { composer(.send(enabled: true), text: $typed) }
            section("Hermes writing (Stop)") { composer(.stop, text: $text) }
            section("AttachmentChip, UploadBar") {
                AttachmentChip(symbol: "film", name: "Saturday.mov", detail: "6.2 GB, via Gofile") {}
                UploadBar(title: Text(verbatim: "Uploading Saturday.mov to Gofile"), fraction: 0.42)
            }
            section("FloatingButton, Toast") {
                FloatingButton("Latest", systemImage: "arrow.down") {}
                Toast("Allowed once")
            }
        case .accent:
            section("Accent on each surface (links, Show Command, selection)") {
                ForEach(Surface.allCases, id: \.self) { s in
                    CardSurface(s) {
                        HStack {
                            Text(verbatim: "Surface.\(s)").textRole(.body)
                            Spacer()
                            Text(verbatim: "Accent").textRole(.body).tone(.accent)
                        }
                    }
                }
            }
            section("Label on the accent fill") {
                ActionRow(primary: Action(id: "p", "Allow Once", emphasis: .primary) {})
            }
        }
    }

    private func composer(_ action: ComposerAction, text: Binding<String>) -> some View {
        ComposerBar(text: text, placeholder: Text(verbatim: "Message Hermes"), action: action, focus: $focus, onSend: {}, onStop: {}) {
            Button("File") {}
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s.points) {
            Text(verbatim: title).textRole(.footnote).tone(.secondary)
            content()
        }
    }
}
