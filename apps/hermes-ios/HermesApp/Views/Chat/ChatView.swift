import HermesCore
import HermesUI
import SwiftUI


/// A conversation (design-rules 1, 2, 6): the system toolbar — the pet leading (iPhone), the
/// chat's name as the title with the chats in its menu, Call trailing — the transcript in one
/// `ChatColumn`, Hermes' open question as the last item of the transcript, and the composer pinned
/// with `safeAreaBar` so the scroll edge effect runs under it.
struct ChatScreen: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let topic: TopicID
    /// iPhone: the chats are in the title's menu; iPad has them in the sidebar.
    let compact: Bool
    @State private var atBottom = true
    @State private var following = true
    /// Read by the scroll callbacks, written every frame: not observed, so scrolling doesn't
    /// re-evaluate the screen.
    @State private var scroll = ScrollMemo()
    /// The heart a caress leaves on the bar's pet, for a second; none with Reduce Motion.
    @State private var heart = false
    @Environment(\.reducesMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    /// The message the composer replies to (16.3), and the original a reply just jumped to (16.2).
    @State private var replyingTo: ChatMessage?
    @State private var highlighted: MessageID?
    /// After a jump to an original: don't resume following the bottom until the owner scrolls.
    @State private var jumped = false
    /// Redraws once a new question's message has waited `questionSettle` for the state.
    @State private var settleTick = 0
    @State private var draft = ComposerDraft()
    @State private var importing = false
    @State private var selecting: SelectableText?
    /// `-scrollProbe`: how the last gesture moved the transcript, for the UI tests.
    @State private var gestureProbe = ""

    var body: some View {
        Group {
            if store.isPrivate(topic) && !model.unlockedTopics.contains(topic) {
                PrivateGate(topic: topic)
            } else {
                conversation
            }
        }
        .navigationTitle(ChatTitle.title(topic, store: store, unlocked: model.unlockedTopics.contains(topic),
                                         active: scenePhase == .active))
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ChatsTitleMenu(enabled: compact))
        .toolbar { toolbar }
        // What the composer's "+" menu and a message's context menu open, presented by the stack's
        // root: a stable owner, unlike a view inside the bar or a row of the lazy stack. SwiftUI
        // waits for the menu to leave before it presents, so the items just set the state.
        .sheet(isPresented: Bindable(model).showCommands) {
            CommandPalette(topic: topic) { inserted in
                draft.text = inserted
                composerFocused = true
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls where !draft.attach(url, securityScoped: true) {
                model.showToast(String(localized: "Couldn't attach \(url.lastPathComponent)"))
            }
        }
        .sheet(item: $selecting) { SelectTextSheet($0.text) }
        .onChange(of: store.caressedAt) {
            guard !reduceMotion else { return }
            heart = true
            Task {
                // `-heartHold`: design reviews keep the heart long enough to be photographed.
                try? await Task.sleep(for: Self.heartHold ? .seconds(5) : CaressTiming.heart)
                heart = false
            }
        }
        // The bar's pet is a still image, not a PetSpriteView (which clears reactions itself): a
        // reaction shows for the time its row would play, then the pet returns to Hermes' state.
        .task(id: store.petReaction) {
            guard let reaction = store.petReaction else { return }
            try? await Task.sleep(for: .seconds(reaction.frameDuration * Double(reaction.frameCount) * 2))
            if store.petReaction == reaction { store.petReaction = nil }
        }
        .task(id: topic) {
            if store.messages(in: topic).isEmpty { await store.loadHistory(topic) }
            store.markRead(topic)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The pet (design-rules 11.3–11.4): a tap caresses it, a long press offers New Pet…; it
        // shows Hermes' state through its animation row.
        ToolbarItem(placement: .topBarLeading) {
            BarMenuButton(image: petImage, title: petLabel, primaryAction: { store.caress() },
                          menuTitle: petLabel, items: [
                              BarMenuItem(String(localized: "New Pet…"), systemImage: "sparkles") { model.showNewPet = true },
                          ])
            .sensoryFeedback(.impact(flexibility: .soft), trigger: store.caressedAt)
            .accessibilityHint(Text("Caresses the pet"))
            .accessibilityAction(named: Text("Caress")) { store.caress() }
            .accessibilityAction(named: Text("New Pet")) { model.showNewPet = true }
            .accessibilityValue(Self.probing && store.caressedAt != nil ? Text(verbatim: "caressed") : Text(verbatim: ""))
            .accessibilityIdentifier("toolbar.pet")
        }
        if topic == .main {
            ToolbarItem(placement: .topBarTrailing) {
                BarButton("Call", systemImage: "phone") { model.startCall() }
                    .accessibilityIdentifier("toolbar.call")
            }
        }
    }

    /// The bar's pet: the still frame Hermes' state (or a reaction) picks, with the caress' heart.
    private var petImage: UIImage {
        guard let frame = PetSpriteView.sheet(store: store)?.frame(store.petAnimation, 0) else {
            return UIImage(systemName: "pawprint") ?? UIImage()
        }
        return PetAvatar.toolbarUIImage(frame, centering: PetSpriteView.centering(store: store, stills: true),
                                        heart: heart ? model.accent : nil)
    }

    /// "Pip, waiting for your approval": the pet and what Hermes is doing.
    private var petLabel: String {
        let doing = store.agent.status != .idle ? (store.agent.task ?? store.petMood.caption) : store.petMood.caption
        // A sentence continued after the name: "Pip, waiting for your approval".
        let continued = doing.prefix(1).lowercased(with: .current) + doing.dropFirst()
        return "\(store.pet?.name ?? String(localized: "Pet")), \(continued)"
    }

    /// Only the connection's state: Hermes' own is already on screen (the pet in the bar, the
    /// draft or typing indicator, the approval card), and a subtitle over a resting transcript
    /// fights the text beneath it.
    private var subtitle: String {
        switch store.connection {
        case .ready: ""
        case .waitingForNetwork: String(localized: "Waiting for network…")
        default: String(localized: "Connecting…")
        }
    }

    private var conversation: some View {
        let questions = store.questions(in: topic)
        // One copy of a question (brief item 3): while it is open its Telegram message (text and
        // buttons) gives way to the card below; once answered, Hermes' edit of it stays as history.
        // A question's message waits a moment for the state that opens the card (≤ 3 s behind),
        // so its buttons don't flash first.
        let asked = Set(questions.compactMap(\.tdlibMessageID))
        _ = settleTick // read, so its change redraws the transcript
        let settled = Date.now.addingTimeInterval(-Self.questionSettle)
        let messages = store.messages(in: topic).filter { m in
            !asked.contains(m.id) && !(m.asksQuestion && m.date > settled)
        }
        return ScrollViewReader { proxy in
            ScrollView {
                ChatColumn {
                    TranscriptStack {
                        if !store.reachedStart.contains(topic), !messages.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .onAppear { Task { await store.loadOlder(topic) } }
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, message in
                            let showTime = i == 0 || message.date.timeIntervalSince(messages[i - 1].date) > 20 * 60
                            if showTime {
                                TranscriptRow(.system, after: i == 0 ? nil : Self.speaker(messages[i - 1])) { TimeLabel(message.date) }
                            }
                            TranscriptRow(Self.speaker(message), after: showTime ? .system : Self.speaker(messages[i - 1])) {
                                MessageRow(message: message,
                                           highlighted: highlighted == message.id,
                                           onReply: { reply(to: message) },
                                           onShowOriginal: { showOriginal($0, proxy: proxy) },
                                           onSelectText: { selecting = SelectableText(text: $0) })
                            }
                            .id(message.id)
                        }
                        if let draft = store.drafts[topic] {
                            TranscriptRow(.hermes, after: messages.last.map(Self.speaker)) { StreamingDraftRow(draft: draft) }
                                .id("draft")
                        } else if store.typing.contains(topic) {
                            TranscriptRow(.hermes, after: messages.last.map(Self.speaker)) { TypingIndicator() }
                                .id("typing")
                        }
                        if let q = questions.first {
                            TranscriptRow(.hermes, after: (store.drafts[topic] != nil || store.typing.contains(topic)) ? .hermes
                                          : messages.last.map(Self.speaker)) {
                                QuestionCard(question: q)
                            }
                            .id(q.id)
                        }
                        ScrollAnchor().id(Self.bottomID)
                    }
                }
            }
            .task(id: store.messages(in: topic).last?.id) {
                guard store.messages(in: topic).last?.asksQuestion == true else { return }
                try? await Task.sleep(for: .seconds(Self.questionSettle))
                settleTick += 1
            }
            // The bottom for where it opens and for a transcript shorter than the screen (it sits
            // on the composer). For size changes only while following: always on, it moved the
            // content under an owner who had scrolled up whenever a row resized.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // Growth (a draft revealing itself, a card appearing or opening) keeps the bottom in
            // view while following, done by the scroll view in its own layout pass. A `scrollTo` on
            // each content-height change did it before and could loop: in the lazy stack, opening
            // a v4 approval card's command made the height alternate 1006 ↔ 1124 pt for ever (the
            // app hung). Not following, no anchor: nothing moves under the owner.
            .defaultScrollAnchor(following ? .bottom : nil, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("chat.transcript")
            .accessibilityValue(Text(verbatim: gestureProbe))
            // The distance from the content's end to the visible bottom (the composer bar's
            // inset counted, it grows at accessibility sizes). A number, not a Bool: a Bool's
            // change back to true was dropped while the lazy stack re-estimated its size.
            .onScrollGeometryChange(for: ScrollFacts.self) { geo in
                ScrollFacts(distance: geo.contentSize.height - (geo.visibleRect.maxY - geo.contentInsets.bottom),
                            offset: geo.contentOffset.y)
            } action: { _, facts in
                scroll.distance = facts.distance
                scroll.offset = facts.offset
                let distance = facts.distance
                let isAtBottom = distance <= Self.bottomSlack
                // At rest only: during a gesture nothing of ours changes. "Latest" coming in (a
                // re-render and a transition) while the keyboard was dragged split the system's
                // layout of a frame in two, and the transcript shook.
                if scroll.phase == .idle, atBottom != isAtBottom { atBottom = isAtBottom }
            }
            // Following the bottom (brief item 1): only the owner turns it off — by scrolling —
            // and only the owner turns it back on: a scroll that comes to rest at the bottom,
            // "Latest", or sending. Growth, edits, drafts and inset changes never change it, so
            // nothing moves under him once he has scrolled up. Nothing scrolls when a gesture ends:
            // the keyboard's interactive dismissal is the system's (see the bar below).
            .onScrollPhaseChange { old, phase in
                scroll.phase = phase
                if old == .idle {
                    scroll.offsetAtStart = scroll.offset
                    scroll.followingAtStart = following
                    if Self.scrollProbe { scroll.startSampling() }
                }
                if phase == .idle, old != .idle {
                    if Self.scrollProbe { scroll.stopSampling(); gestureProbe = scroll.probeSummary }
                    let isAtBottom = scroll.distance <= Self.bottomSlack
                    if atBottom != isAtBottom { atBottom = isAtBottom }
                }
                if phase == .interacting { following = false; jumped = false }
                if phase == .idle, old != .idle, old != .animating, !jumped {
                    // A gesture that didn't move the transcript (a tap, a swipe to reply, a drag
                    // only dismissing the keyboard) leaves following as it was; one that did
                    // follows again only if it rests at the bottom.
                    let moved = abs(scroll.offset - scroll.offsetAtStart) > Self.stillSlack
                    if !moved { following = scroll.followingAtStart } else if scroll.distance <= Self.bottomSlack { following = true }
                }
            }
            .onChange(of: messages.last?.id) {
                if messages.last?.isOutgoing == true { following = true; jumped = false }
                if following { withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            // The bar's inset growing at rest while following (the keyboard coming up, a reply
            // chip, a longer draft): the last message stays above the composer (16.3). The scroll
            // view's size-change anchor doesn't cover a safe-area inset (measured: the keyboard's
            // 78 → 379 pt left the offset where it was). Never during a gesture and never as the
            // inset shrinks: the keyboard's interactive dismissal is the system's alone.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { old, new in
                if new > old, following, scroll.phase == .idle { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: replyingTo?.id) {
                if following { withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            .onChange(of: questions.map(\.id)) {
                if following { withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            // "Latest" floats over the transcript, on its safe area (so just above the bar, with
            // the keyboard too), not in the bar: there its coming and going changed the bar's
            // height, so the inset, so "at the bottom" — while the keyboard was dragged it
            // flickered in and out and moved the transcript.
            .overlay(alignment: .bottom) {
                if !atBottom {
                    FloatingButton("Latest", systemImage: "arrow.down") {
                        jumped = false
                        following = true
                        withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    .inset(.bottom, .s)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: atBottom)
            .onChange(of: atBottom) { if Self.scrollProbe, scroll.phase != .idle { scroll.latestChanges += 1 } }
            .safeAreaBar(edge: .bottom) {
                ChatColumn {
                    Composer(topic: topic, draft: draft, focused: $composerFocused, replyingTo: $replyingTo,
                             onAttachFile: { importing = true })
                }
                .keyboardGap()
            }
        }
    }

    private func reply(to message: ChatMessage) {
        replyingTo = message
        composerFocused = true
    }

    /// Scrolls to a reply's original and lights it for a moment, loading older pages first when
    /// it isn't loaded yet (16.2). With Reduce Motion the jump isn't animated.
    private func showOriginal(_ id: MessageID, proxy: ScrollViewProxy) {
        // Not following first: older pages growing the content mustn't pull the view back down,
        // and being at the bottom when the jump starts mustn't turn following back on.
        jumped = true
        following = false
        Task {
            guard await store.loadAround(id, in: topic) else {
                model.showToast(String(localized: "Message deleted"))
                return
            }
            // Let the new rows lay out before scrolling to one of them.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(100))
            withAnimation(reduceMotion ? nil : .smooth) { proxy.scrollTo(id, anchor: .center) }
            highlighted = id
            try? await Task.sleep(for: .seconds(1.5))
            if highlighted == id { highlighted = nil }
        }
    }

    static let questionSettle: TimeInterval = 5
    /// How close to the end still counts as "at the bottom".
    static let bottomSlack: CGFloat = 40
    /// A gesture that moved the transcript less than this didn't scroll it.
    static let stillSlack: CGFloat = 4
    static let bottomID = "bottom"
    static let probing = ProcessInfo.processInfo.arguments.contains("-geometryProbe")
    static let scrollProbe = ProcessInfo.processInfo.arguments.contains("-scrollProbe")
    static let heartHold = ProcessInfo.processInfo.arguments.contains("-heartHold")

    static func speaker(_ m: ChatMessage) -> Speaker { m.isOutgoing ? .owner : .hermes }
}

/// The transcript's live scroll facts, outside SwiftUI's observation.
private final class ScrollMemo: NSObject {
    var distance: CGFloat = 0
    var offset: CGFloat = 0
    var phase: ScrollPhase = .idle
    /// Where the last gesture started, and whether the transcript was following then.
    var offsetAtStart: CGFloat = 0
    var followingAtStart = true
    /// `-scrollProbe`: the offset each frame of the gesture showed, read by a display link at
    /// each refresh — what the screen drew, not the steps a frame's layout went through.
    var offsets: [CGFloat] = []
    /// `-scrollProbe`: how often "Latest" came or went during the gesture.
    var latestChanges = 0
    private var link: CADisplayLink?

    func startSampling() {
        offsets = [offset]
        latestChanges = 0
        link?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stopSampling() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() { offsets.append(offset) }

    /// "frames=… reversals=… maxBack=… maxStep=…": a drag moves the offset one way, by steps the
    /// finger makes; a jump is a step back or a step far longer than the others. Under a point
    /// is rounding (a third of a point on a 3× screen).
    var probeSummary: String {
        let steps = zip(offsets.dropFirst(), offsets).map { $0 - $1 }.filter { abs($0) >= 1 }
        let direction: CGFloat = steps.reduce(0, +) >= 0 ? 1 : -1
        let backs = steps.filter { $0 * direction < 0 }.map(abs)
        let reversals = zip(steps.dropFirst(), steps).filter { ($0 > 0) != ($1 > 0) }.count
        let maxStep = steps.map(abs).max() ?? 0
        return "frames=\(offsets.count) reversals=\(reversals) maxBack=\(Int((backs.max() ?? 0).rounded())) maxStep=\(Int(maxStep.rounded())) latest=\(latestChanges)"
    }
}

private struct ScrollFacts: Equatable {
    var distance: CGFloat
    var offset: CGFloat
}


/// Select Text's sheet item.
private struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}
