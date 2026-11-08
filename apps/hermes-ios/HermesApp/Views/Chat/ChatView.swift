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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool

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
                try? await Task.sleep(for: CaressTiming.heart)
                heart = false
            }
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
            BarButton(Text(petLabel), action: { store.caress() }) {
                if let frame = PetSpriteView.sheet(store: store)?.frame(store.petAnimation, 0) {
                    PetAvatar.toolbarImage(frame, heart: heart ? model.accent : nil)
                } else {
                    Image(systemName: "pawprint")
                }
            }
            .contextMenu {
                Button { model.showNewPet = true } label: { Label("New Pet…", systemImage: "sparkles") }
            }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: store.caressedAt)
            .accessibilityHint(Text("Caresses the pet"))
            .accessibilityAction(named: Text("Caress")) { store.caress() }
            .accessibilityAction(named: Text("New Pet")) { model.showNewPet = true }
            .accessibilityIdentifier("toolbar.pet")
        }
        if topic == .main {
            ToolbarItem(placement: .topBarTrailing) {
                BarButton("Call", systemImage: "phone") { model.startCall() }
                    .accessibilityIdentifier("toolbar.call")
            }
        }
    }

    /// "Pip, waiting for your approval": the pet and what Hermes is doing.
    private var petLabel: String {
        let doing = store.agent.status != .idle ? (store.agent.task ?? store.petMood.caption) : store.petMood.caption
        return "\(store.pet?.name ?? String(localized: "Pet")), \(doing)"
    }

    /// Hermes' state in this chat, or the connection's, in words (secondary, as Apple's subtitles).
    private var subtitle: String {
        if store.connection != .ready {
            return store.connection == .waitingForNetwork ? String(localized: "Waiting for network…") : String(localized: "Connecting…")
        }
        let a = store.agent
        if a.status != .idle, a.chat == topic || a.busyChats.contains(topic) { return a.task ?? a.status.label }
        return ""
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
                                MessageRow(message: message, showsButtons: !asked.contains(message.id))
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
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.visibleRect.maxY >= geo.contentSize.height - 80
            } action: { _, isAtBottom in
                atBottom = isAtBottom
                if isAtBottom { following = true }
            }
            // The transcript follows its bottom as it grows (new messages, a draft, the card) until
            // the owner scrolls away, and again once they're back at the bottom (as Messages).
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { following = false }
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
            .onChange(of: questions.map(\.id)) {
                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .safeAreaBar(edge: .bottom) {
                ChatColumn {
                    VGroup(alignment: .center, spacing: .s) {
                        if !atBottom {
                            FloatingButton("Latest", systemImage: "arrow.down") {
                                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                        Composer(topic: topic, focused: $composerFocused)
                    }
                }
                .inset(.bottom, .xs)
                .animation(.snappy, value: atBottom)
            }
        }
    }

    static let bottomID = "bottom"

    static func speaker(_ m: ChatMessage) -> Speaker { m.isOutgoing ? .owner : .hermes }
}
