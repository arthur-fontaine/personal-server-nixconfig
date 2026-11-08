import HermesCore
import SwiftUI

struct ChatView: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let topic: TopicID
    @State private var atBottom = true
    @State private var showInspector = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        Group {
            if store.isPrivate(topic) && !model.unlockedTopics.contains(topic) {
                PrivateGate(topic: topic)
            } else {
                conversation
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            ChatInspector(topic: topic)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
        .onAppear {
            // Wide landscape iPads have room for the inspector from the start.
            if sizeClass == .regular, UIScreen.main.bounds.width >= 1180 { showInspector = true }
        }
        .task(id: topic) {
            if store.messages(in: topic).isEmpty { await store.loadHistory(topic) }
            store.markRead(topic)
        }
    }

    private var title: String {
        topic == .main ? (store.bot?.title ?? "Hermes") : (store.thread(topic)?.name ?? String(localized: "Sub-chat"))
    }

    private var conversation: some View {
        let messages = store.messages(in: topic)
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !store.reachedStart.contains(topic), !messages.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .onAppear { Task { await store.loadOlder(topic) } }
                }
                ForEach(Array(messages.enumerated()), id: \.element.id) { i, message in
                    if i == 0 || message.date.timeIntervalSince(messages[i - 1].date) > 20 * 60 {
                        TimeSeparator(date: message.date)
                    }
                    MessageRow(message: message)
                        .id(message.id)
                }
                if let draft = store.drafts[topic] {
                    StreamingDraftRow(draft: draft).id("draft")
                } else if store.typing.contains(topic) {
                    TypingDots().padding(.vertical, 6).id("typing")
                }
                Color.clear.frame(height: 1).id(Self.bottomID)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            // A readable column on wide iPads instead of 1300 pt lines. (Not containerRelativeFrame:
            // it ignores the safe area of iOS 26's floating sidebar.)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .scrollTargetLayout()
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.visibleRect.maxY >= geo.contentSize.height - 80
        } action: { _, isAtBottom in
            atBottom = isAtBottom
        }
        .onChange(of: messages.last?.id) { old, _ in
            // Follow new messages only when already at the bottom, or when the owner just sent one.
            if atBottom || messages.last?.isOutgoing == true {
                withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
        .onChange(of: store.drafts[topic]?.text.text) {
            if atBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if !atBottom {
                    Button {
                        withAnimation(.smooth) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .transition(.scale.combined(with: .opacity))
                }
                QuestionTray(topic: topic)
                Composer(topic: topic, focused: $composerFocused)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .animation(.snappy, value: atBottom)
        }
        }
    }

    static let bottomID = "bottom"

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    if store.isPrivate(topic) { Image(systemName: "lock.fill").font(.caption2) }
                    Text(title).font(.headline)
                }
                if store.connection != .ready {
                    Text(store.connection == .waitingForNetwork ? String(localized: "Waiting for network…") : String(localized: "Connecting…"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if isWorkingHere {
                    AgentStatusLabel(agent: store.agent, compact: true)
                } else if let preset = store.subchat(topic)?.preset {
                    Text(PresetNames.name(preset)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if topic == .main {
            ToolbarItem(placement: .primaryAction) {
                Button { model.startCall() } label: { Label("Call", systemImage: "phone") }
            }
        }
        if sizeClass == .regular {
            // Calling and the inspector are unrelated: two glass groups, not one.
            if topic == .main { ToolbarSpacer(.fixed, placement: .primaryAction) }
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
            }
        }
    }

    private var isWorkingHere: Bool {
        let a = store.agent
        return a.status != .idle && (a.chat == topic || a.busyChats.contains(topic))
    }
}

/// iPad trailing column: what Hermes is doing, what it asks, and this sub-chat's policy.
struct ChatInspector: View {
    @Environment(HermesStore.self) private var store
    let topic: TopicID

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    PetSpriteView(animation: nil, size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        AgentStatusLabel(agent: store.agent)
                        if let since = store.agent.since, store.agent.status != .idle {
                            Text(since, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        if let p = store.agent.progress { Text(p).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if !store.questions.isEmpty {
                Section("Waiting for you") {
                    ForEach(store.questions) { q in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.summary ?? q.text).font(.subheadline).lineLimit(3)
                            Text(q.chat == .main ? String(localized: "Main chat") : store.thread(q.chat)?.name ?? String(localized: "Sub-chat"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let sub = store.subchat(topic) {
                Section("Sub-chat") {
                    LabeledContent("Preset", value: sub.preset.map(PresetNames.name) ?? String(localized: "Custom"))
                    LabeledContent("Encrypted", value: sub.encrypted
                                   ? (sub.unlocked ? String(localized: "Unlocked") : String(localized: "Locked")) : String(localized: "No"))
                    if let ttl = sub.ttl { LabeledContent("Expires", value: PresetNames.ttl(ttl)) }
                    if let at = sub.expiresAt { LabeledContent("At", value: at.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
