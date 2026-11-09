import SwiftUI

/// One page per HermesUI component, every variant (design-rules 9.6). The app shows a page with
/// `-catalog <page>`; the screenshot tour renders each in light, dark and at AX5 for the critic.
public enum CatalogPage: String, CaseIterable, Sendable {
    case type, surfaces, actions, approval, chat, files, composer, accent
    case buttons, lists, metrics, call, onboarding, bar
}

public struct ComponentCatalog: View {
    let page: CatalogPage
    /// The pet's idle frame (the app passes the bundled sprite's), for `PetAvatar`.
    let petFrame: CGImage?
    @State private var text = ""
    @State private var typed = "Can you also check the photos backup?"
    @FocusState private var focus: Bool

    public init(page: CatalogPage, petFrame: CGImage? = nil) {
        self.page = page
        self.petFrame = petFrame
    }

    public var body: some View {
        switch page {
        case .lists: lists.catalogTitle(page)
        case .onboarding: onboarding.catalogTitle(page)
        case .bar: scroll.catalogTitle(page).toolbar { barItems }
        default: scroll.catalogTitle(page)
        }
    }

    private var scroll: some View {
        ScrollView {
            ChatColumn {
                VStack(alignment: .leading, spacing: Spacing.xl.points) {
                    content
                }
                .inset(.vertical, .m)
            }
        }
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
                        Capsule().fill(AccentFillStyle()).frame(width: sp.points, height: Spacing.xs.points)
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
                ActionRow(primary: Action(id: "busy.allow", "Allow Once", emphasis: .primary, isBusy: true) {},
                          others: [Action(id: "busy.deny", "Deny", emphasis: .destructive) {}])
            }
            section("Long labels stack, primary first") {
                ActionRow(primary: Action(id: "p", verbatim: "Autoriser pour toute la session", emphasis: .primary) {},
                          others: [Action(id: "d", verbatim: "Refuser et expliquer pourquoi", emphasis: .destructive) {}])
            }
        case .approval:
            section("ApprovalCard") {
                ApprovalCard(question: "Hermes wants to delete the backup snapshots older than 90 days on the external disk, freeing about 212 GB. Auto mode asks because deleting can't be undone.",
                             command: "terminal: restic -r /Volumes/Backup/restic forget --keep-within 90d --prune",
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
                VStack(alignment: .trailing, spacing: Rhythm.bubbles.spacing.points) {
                    UserBubble("Yes, go ahead")
                    UserBubble("What happened with the backup last night? It was supposed to run at 3.", state: .pending)
                    UserBubble("Remind me to call mum", state: .failed)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            section("MessageText + CodeBlock + QuoteBlock") {
                MessageBlocks {
                    MessageText(verbatim: "The external disk was full, so restic stopped before pruning:")
                    CodeBlock("Fatal: unable to save snapshot: no space left on device")
                    QuoteBlock(AttributedString("Keep the last 90 days, prune the rest."))
                }
            }
            section("PetAvatar at each size (the circle filled to show it), the bar's image without and with the heart") {
                if let petFrame {
                    HStack(alignment: .bottom, spacing: Spacing.m.points) {
                        ForEach([PetSize.toolbar, .row, .hero], id: \.self) { size in
                            PetAvatar(size) { CenteredPet(frame: petFrame, centering: PetCentering(frames: [petFrame])) }
                            .background(Surface.fill.style, in: Circle())
                        }
                    }
                    HStack(spacing: Spacing.m.points) {
                        PetAvatar<EmptyView>.toolbarImage(petFrame, centering: PetCentering(frames: [petFrame]))
                        PetAvatar<EmptyView>.toolbarImage(petFrame, centering: PetCentering(frames: [petFrame]), heart: PetAccent(sprite: petFrame))
                    }
                }
            }
            section("ReplyContext (above Hermes, above the owner's bubble, loading, deleted), ReplyChip") {
                ReplyContext(.original(author: Text(verbatim: "You"), excerpt: Text(verbatim: "Remind me to call mum tonight")),
                             above: .hermes, accessibilityLabel: Text(verbatim: "Reply to you: Remind me to call mum tonight")) {}
                ReplyPair {
                    ReplyContext(.original(author: Text(verbatim: "Hermes"),
                                           excerpt: Text(verbatim: "The external disk was full, so restic stopped before pruning:")),
                                 above: .owner, accessibilityLabel: Text(verbatim: "Reply to Hermes")) {}
                } bubble: { UserBubble("Here's the video from Saturday for Léa") }
                .frame(maxWidth: .infinity, alignment: .trailing)
                ReplyPair {
                    ReplyContext(.original(author: Text(verbatim: "Hermes"),
                                           excerpt: Text(verbatim: "The external disk was full, so restic stopped before pruning:")),
                                 above: .owner, accessibilityLabel: Text(verbatim: "Reply to Hermes")) {}
                } bubble: { UserBubble("Yes") }
                .frame(maxWidth: .infinity, alignment: .trailing)
                ReplyContext(.loading, above: .hermes, accessibilityLabel: Text(verbatim: "Reply")) {}
                ReplyContext(.deleted, above: .hermes, accessibilityLabel: Text(verbatim: "Reply to a deleted message")) {}
                ReplyChip(author: Text(verbatim: "Hermes"), excerpt: Text(verbatim: "Found 41 snapshots older than 90 days"),
                          accessibilityLabel: Text(verbatim: "Replying to Hermes")) {}
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
                UploadBar(title: Text(verbatim: "Uploading Saturday.mov to Gofile"), progress: Self.sampleUpload)
            }
            section("FloatingButton, Toast") {
                FloatingButton("Latest", systemImage: "arrow.down") {}
                Toast("Allowed once")
            }
        case .accent:
            section("Accent text on each surface: links only (15.2)") {
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
            section("The pet's colour as a fill, its label black or white (15.1)") {
                ActionRow(primary: Action(id: "p", "Allow Once", emphasis: .primary) {})
            }
            section("A light tint behind primary text: selection, the owner's bubble (15.3)") {
                UserBubble("Yes, go ahead").frame(maxWidth: .infinity, alignment: .trailing)
            }
        default:
            phase2
        }
    }

    // MARK: Phase 2's components

    @State private var choice = "aside"
    @State private var sidebarSelection = 0
    @State private var muted = false

    @ViewBuilder private var phase2: some View {
        switch page {
        case .buttons:
            section("PrimaryButton (default, symbol, busy, full width)") {
                PrimaryButton("Unlock", systemImage: "faceid") {}
                PrimaryButton("Unlocking…", isBusy: true) {}
                PrimaryButton("Continue with Telegram", fullWidth: true) {}
            }
            section("SecondaryButton (default, symbol, full width)") {
                SecondaryButton("Not Now") {}
                SecondaryButton("Open Telegram", systemImage: "paperplane", fullWidth: true) {}
            }
            section("ConfirmButton, DismissButton (.close, .cancel) — in a sheet's bar") {
                HStack(spacing: Spacing.s.points) {
                    DismissButton(.close) {}
                    DismissButton(.cancel) {}
                    Spacer()
                    ConfirmButton("Create") {}
                }
            }
            section("Answer buttons (lock screen, Dynamic Island): refusal, the pet's fill") {
                HStack(spacing: Spacing.xs.points) {
                    Button {} label: { AnswerLabel("Deny") }.answerButton(destructive: true)
                    Button {} label: { AnswerLabel("Allow Once") }.answerButton(destructive: false)
                }
            }
        case .metrics:
            section("Sparkline (.line)") {
                Sparkline(ChartSeries([3, 4, 3.5, 6, 5, 7, 6.5, 9, 8, 7, 9.5, 11]), label: Text(verbatim: "CPU"))
            }
            section("Sparkline (.bars)") {
                Sparkline(ChartSeries([2, 0, 5, 3, 8, 6, 1, 4, 7, 2, 9, 3]), kind: .bars, label: Text(verbatim: "Calls"))
            }
            section("UsageBar (42 %, 95 % critical)") {
                UsageBar(Self.sampleUpload, label: Text(verbatim: "Storage used"))
                UsageBar(Self.nearlyFull, label: Text(verbatim: "Storage used"))
            }
        case .call:
            section("CallControls: toggle off, toggle on, End") {
                CallControls {
                    CallButton(Text(verbatim: "Mute"), systemImage: "mic.fill", kind: .toggle(isOn: false)) {}
                    CallButton(Text(verbatim: "Speaker"), systemImage: "speaker.wave.3.fill", kind: .toggle(isOn: true)) {}
                    CallButton(Text(verbatim: "End"), systemImage: "phone.down.fill", kind: .end) {}
                }
                .callBackdrop()
            }
            section("Long labels wrap in their column") {
                CallControls {
                    CallButton(Text(verbatim: "Couper le micro"), systemImage: "mic.slash.fill", kind: .toggle(isOn: muted)) { muted.toggle() }
                    CallButton(Text(verbatim: "Haut-parleur"), systemImage: "speaker.fill", kind: .toggle(isOn: false)) {}
                    CallButton(Text(verbatim: "Raccrocher"), systemImage: "phone.down.fill", kind: .end) {}
                }
                .callBackdrop()
            }
        case .bar:
            section("BarButton, BarMenuButton: in this page's bar (the pet, leading; the call, trailing)") {
                Text(verbatim: "Tap the pet: caress. Long-press: its menu.").textRole(.body).tone(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private var lists: some View {
        List {
            Section {
                let rows: [(String, DownloadRow.State)] = [
                    ("LFM3-Omni-2B · 1.32 GB · Wi-Fi only", .absent), ("412 MB of 1.32 GB", .downloading(fraction: 0.31)),
                    ("Waiting for Wi-Fi · 1.32 GB", .waiting(fraction: 0.31)), ("LFM3-Omni-2B · 1.32 GB", .ready),
                    ("Download failed: The network connection was lost.", .failed)]
                ForEach(rows, id: \.0) { detail, state in
                    DownloadRow(Text(verbatim: "On-Device Voice"), detail: Text(verbatim: detail), systemImage: "waveform",
                                state: state, onDownload: {}, onCancel: {}, onDelete: {})
                }
            } header: { Text(verbatim: "DownloadRow (absent, downloading, waiting, ready, failed)") }
            Section {
                ListActionRow(Text(verbatim: "Turn On Notifications"), detail: nil, systemImage: "bell") {}
                ListActionRow(Text(verbatim: "Reasoning Effort"), detail: Text(verbatim: "How hard the model thinks"), systemImage: "brain") {}
                ListActionRow(Text(verbatim: "Compact"), detail: Text(verbatim: "Fills the composer"), systemImage: "rectangle.compress.vertical", fillsComposer: true) {}
                ListActionRow(Text(verbatim: "Reinstall Now"), detail: nil, systemImage: "arrow.triangle.2.circlepath", isBusy: true) {}
                ListActionRow(Text(verbatim: "Forget This Chat"), detail: nil, systemImage: "trash", destructive: true) {}
            } header: { Text(verbatim: "ListActionRow (plain, detail, fills composer, busy, destructive)") }
            Section {
                ForEach([("aside", "Aside", "bubble.left.and.bubble.right"), ("project", "Project", "folder"),
                         ("temp", "Temp", "timer")], id: \.0) { id, title, symbol in
                    ChoiceRow(Text(verbatim: title), detail: Text(verbatim: "What this kind of sub-chat keeps."), systemImage: symbol,
                              isSelected: choice == id) { choice = id }
                }
                ChoiceRow(Text(verbatim: "No icon, no detail"), isSelected: choice == "plain") { choice = "plain" }
            } header: { Text(verbatim: "ChoiceRow") }
            Section {
                SidebarRow(Text(verbatim: "Main chat"), systemImage: "bubble.left.and.bubble.right", selected: sidebarSelection == 0,
                           action: { sidebarSelection = 0 }) { UnreadBadge(nil) }
                SidebarRow(Text(verbatim: "Lisbon trip"), systemImage: "text.bubble", selected: sidebarSelection == 1,
                           action: { sidebarSelection = 1 }) { UnreadBadge(Text(verbatim: "3")) }
            } header: { Text(verbatim: "SidebarRow (selected: the pet's light tint), UnreadBadge") }
            Section {
                Label { Text(verbatim: "Demo data: a wide symbol stays in its column") } icon: { Image(systemName: "theatermasks") }
                Label { Text(verbatim: "Notifications") } icon: { Image(systemName: "bell") }
                Toggle(isOn: .constant(true)) { Label { Text(verbatim: "A switch keeps the pet's fill") } icon: { Image(systemName: "switch.2") } }
            } header: { Text(verbatim: "groupedRows(): one icon column, monochrome") }
        }
        .groupedRows()
        .safeAreaBar(edge: .bottom) {
            SidebarFooter {
                SidebarFooterRow(Text(verbatim: "Dashboard"), systemImage: "gauge.with.dots.needle.33percent", selected: true) {}
                SidebarFooterRow(Text(verbatim: "Settings"), systemImage: "gear", selected: false) {}
            }
        }
    }

    private var onboarding: some View {
        OnboardingPage(title: Text(verbatim: "Your phone number"),
                       message: Text(verbatim: "Hermes signs in to Telegram as you, to talk with your agent."),
                       hero: {
                           if let petFrame {
                               PetAvatar(.hero) { CenteredPet(frame: petFrame, centering: PetCentering(frames: [petFrame])) }
                           }
                       },
                       fields: { TextField(text: .constant("+33 6 12 34 56 78")) { Text(verbatim: "Phone") }.inputField() },
                       actions: {
                           PrimaryButton("Next", fullWidth: true) {}
                           SecondaryButton("Not Now", fullWidth: true) {}
                       })
    }

    @ToolbarContentBuilder private var barItems: some ToolbarContent {
        if let petFrame {
            ToolbarItem(placement: .topBarLeading) {
                BarMenuButton(image: PetAvatar<EmptyView>.toolbarUIImage(petFrame, centering: PetCentering(frames: [petFrame])),
                              title: "Pip", primaryAction: {}, menuTitle: "Pip",
                              items: [BarMenuItem("New Pet…", systemImage: "sparkles") {}])
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            BarButton(Text(verbatim: "Call")) {} icon: { Image(systemName: "phone") }
        }
    }

    static let nearlyFull: Progress = {
        let p = Progress(totalUnitCount: 100)
        p.completedUnitCount = 95
        return p
    }()

    static let sampleUpload: Progress = {
        let p = Progress(totalUnitCount: 100)
        p.completedUnitCount = 42
        return p
    }()

    private func composer(_ action: ComposerAction, text: Binding<String>) -> some View {
        ComposerBar(text: text, placeholder: Text(verbatim: "Message"), action: action, focus: $focus, onSend: {}, onStop: {}) {
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

private extension View {
    func catalogTitle(_ page: CatalogPage) -> some View {
        navigationTitle(Text(verbatim: "HermesUI · \(page.rawValue)")).navigationBarTitleDisplayMode(.inline)
    }
}
