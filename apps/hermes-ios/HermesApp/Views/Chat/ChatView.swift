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
    /// The heart a caress leaves on the bar's pet, for a second; none with Reduce Motion.
    @State private var heart = false
    @Environment(\.reducesMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    /// The message the composer replies to (16.3), and the original a reply just jumped to (16.2).
    @State private var replyingTo: ChatMessage?
    @State private var highlighted: MessageID?
    /// After a jump to an original: don't resume following the bottom until the owner scrolls.
    @State private var jumped = false

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
        let messages = store.messages(in: topic)
        let questions = store.questions(in: topic)
        // A message whose question is open shows it as the card below, not as buttons too.
        let asked = Set(questions.compactMap(\.messageID))
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
                                MessageRow(message: message, showsButtons: !asked.contains(message.id),
                                           highlighted: highlighted == message.id,
                                           onReply: { reply(to: message) },
                                           onShowOriginal: { showOriginal($0, proxy: proxy) })
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
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // The distance from the content's end to the visible bottom (the composer bar's
            // inset counted, it grows at accessibility sizes). A number, not a Bool: a Bool's
            // change back to true was dropped while the lazy stack re-estimated its size.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height - (geo.visibleRect.maxY - geo.contentInsets.bottom)
            } action: { _, distance in
                let isAtBottom = distance <= 80
                atBottom = isAtBottom
                if isAtBottom, !jumped { following = true }
            }
            // The transcript follows its bottom as it grows (new messages, a draft, the card) until
            // the owner scrolls away, and again once they're back at the bottom (as Messages).
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { following = false; jumped = false }
            }
            .onChange(of: messages.last?.id) {
                if following || messages.last?.isOutgoing == true {
                    withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            // Any growth — a draft revealing itself, a card appearing — while following.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                if following { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            // The composer bar growing (a reply chip, a file, a longer draft) while following:
            // the last message stays above it, the rhythm's gap apart (16.3; round 6's S4).
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.bottom } action: { _, _ in
                if following { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: replyingTo?.id) {
                if following { withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            .onChange(of: questions.map(\.id)) {
                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .safeAreaBar(edge: .bottom) {
                ChatColumn {
                    VGroup(alignment: .center, spacing: .s) {
                        if !atBottom {
                            FloatingButton("Latest", systemImage: "arrow.down") {
                                jumped = false
                                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                        Composer(topic: topic, focused: $composerFocused, replyingTo: $replyingTo)
                    }
                }
                .animation(.snappy, value: atBottom)
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

    static let bottomID = "bottom"
    static let probing = ProcessInfo.processInfo.arguments.contains("-geometryProbe")
    static let heartHold = ProcessInfo.processInfo.arguments.contains("-heartHold")

    static func speaker(_ m: ChatMessage) -> Speaker { m.isOutgoing ? .owner : .hermes }
}
