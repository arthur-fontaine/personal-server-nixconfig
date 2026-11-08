import HermesCore
import SwiftUI

/// iPad sidebar: the pet's card on top, then the chats, then the other sections.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(HermesStore.self) private var store

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                // A selectable row like the others: the list draws its selection.
                PetCard().tag(SidebarItem.section(.pet))
            }
            Section("Chats") {
                ThreadRow(thread: store.mainThread)
                    .badge(store.mainThread.unreadCount)
                    .tag(SidebarItem.topic(.main))
                ForEach(store.threads) { thread in
                    ThreadRow(thread: thread).badge(thread.unreadCount).tag(SidebarItem.topic(thread.id))
                }
                Button { model.showNewSubchat = true } label: {
                    Label("New Sub-chat", systemImage: "plus.bubble")
                }
                .foregroundStyle(.tint)
            }
            Section {
                ForEach([AppSection.dashboard, .settings]) { s in
                    Label(s.title, systemImage: s.symbol).tag(SidebarItem.section(s))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Hermes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.startCall() } label: { Label("Call", systemImage: "phone.fill") }
            }
        }
    }

    enum SidebarItem: Hashable {
        case topic(TopicID)
        case section(AppSection)
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding {
            model.section == .chat ? .topic(model.selectedTopic ?? .main) : .section(model.section)
        } set: { item in
            switch item {
            case .topic(let t)?: model.open(topic: t)
            case .section(let s)?: model.section = s
            case nil: break
            }
        }
    }
}

/// The pet at a glance: mood and needs; selecting it opens the Pet section.
struct PetCard: View {
    @Environment(HermesStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            PetSpriteView(animation: nil, size: 64)
                .background(Circle().fill(store.petMood.tint.opacity(0.18)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.pet?.name ?? "Pip").font(.headline).fontDesign(.rounded)
                    Text("Lv \(store.pet?.level ?? 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                AgentStatusLabel(agent: store.agent, compact: true)
                if let pet = store.pet {
                    HStack(spacing: 6) {
                        NeedPip(symbol: "fork.knife", value: 1 - pet.hunger)
                        NeedPip(symbol: "bolt.fill", value: pet.energy)
                        NeedPip(symbol: "heart.fill", value: pet.happiness)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct NeedPip: View {
    let symbol: String
    let value: Double

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            // ProgressView, not Gauge: at this size the capacity gauge draws a knob.
            ProgressView(value: value)
                .tint(value < 0.25 ? Color.red : .accentColor)
                .frame(width: 22)
        }
    }
}

/// Main chat and sub-chats, as a list (iPhone sheet) — the iPad sidebar uses `ThreadRow` directly.
struct ThreadList: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Binding var selection: TopicID?

    var body: some View {
        List {
            Section {
                Button { selection = .main } label: { ThreadRow(thread: store.mainThread) }
                    .badge(store.mainThread.unreadCount)
            }
            Section("Sub-chats") {
                ForEach(store.threads) { thread in
                    Button { selection = thread.id } label: { ThreadRow(thread: thread) }
                        .badge(thread.unreadCount)
                }
                Button { model.showNewSubchat = true } label: {
                    Label("New Sub-chat", systemImage: "plus.bubble")
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct ThreadRow: View {
    @Environment(HermesStore.self) private var store
    let thread: ChatThread

    var body: some View {
        HStack(spacing: 12) {
            ThreadIcon(thread: thread, isPrivate: store.isPrivate(thread.id))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.isMain ? "Hermes" : thread.name).font(.body.weight(.medium)).lineLimit(1)
                    if store.isPrivate(thread.id) {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if store.agent.busyChats.contains(thread.id) || (store.agent.status.isBusy && store.agent.chat == thread.id) {
                        ProgressView().controlSize(.mini)
                    } else if let date = thread.lastMessage?.date {
                        Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var preview: String {
        if store.isPrivate(thread.id) { return store.subchat(thread.id)?.unlocked == true ? "Unlocked" : "Private" }
        if let preset = store.subchat(thread.id)?.preset, thread.lastMessage == nil { return preset.capitalized }
        guard let m = thread.lastMessage else { return thread.isMain ? "Your main chat" : "" }
        let text = m.displayText.replacingOccurrences(of: "\n", with: " ")
        if text.isEmpty, !m.fileLinks.isEmpty || m.attachment != nil { return (m.isOutgoing ? "You: " : "") + "File" }
        return (m.isOutgoing ? "You: " : "") + text
    }
}

struct ThreadIcon: View {
    let thread: ChatThread
    let isPrivate: Bool

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            if thread.isMain {
                PetSpriteView(animation: .idle, size: 30, still: true)
            } else if let emoji = thread.iconEmoji {
                Text(emoji).font(.system(size: 18))
            } else {
                Text(String(thread.name.prefix(1))).font(.headline).foregroundStyle(.white)
            }
        }
        .frame(width: 38, height: 38)
    }

    private var color: Color {
        thread.isMain ? .accentColor.opacity(0.35) : Color(rgb: thread.iconColor).opacity(isPrivate ? 0.5 : 0.85)
    }
}

extension Color {
    init(rgb: Int32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
