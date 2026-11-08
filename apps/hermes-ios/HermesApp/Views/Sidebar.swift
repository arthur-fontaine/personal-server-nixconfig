import HermesCore
import HermesUI
import SwiftUI

/// iPad sidebar (regular width): the pet (its sheet, as from the iPhone's toolbar), the chats,
/// then Dashboard and Settings. System sidebar rows; names through `ChatTitle`, so a private
/// sub-chat is "Private chat" here too (design-rules 1.4).
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(HermesStore.self) private var store

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                Button { model.showPet = true } label: {
                    Label {
                        VGroup(alignment: .leading, spacing: .xxs) {
                            Text(store.pet?.name ?? String(localized: "Pet")).textRole(.headline).tone(.primary)
                            AgentStatusLabel(agent: store.agent, compact: true)
                        }
                    } icon: {
                        PetSpriteView(animation: nil, size: .row)
                    }
                }
                .accessibilityIdentifier("sidebar.pet")
            }
            Section("Chats") {
                row(.main, unread: store.mainThread.unreadCount)
                ForEach(store.threads) { thread in row(thread.id, unread: thread.unreadCount) }
                Button { model.showNewSubchat = true } label: { Label("New Sub-chat", systemImage: "plus") }
            }
            Section {
                ForEach([AppSection.dashboard, .settings]) { s in
                    Label(s.title, systemImage: s.symbol).tag(SidebarItem.section(s))
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The tag outermost: the list's selection reads it from the row itself.
    private func row(_ topic: TopicID, unread: Int) -> some View {
        Label(ChatTitle.name(topic, store: store), systemImage: ChatTitle.symbol(topic, store: store))
            .badge(unread)
            .accessibilityIdentifier("sidebar.chat.\(topic)")
            .tag(SidebarItem.topic(topic))
    }

    enum SidebarItem: Hashable {
        case topic(TopicID)
        case section(AppSection)
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding {
            switch model.section {
            case .chat, .pet: .topic(model.selectedTopic ?? .main)
            case .dashboard, .settings: .section(model.section)
            }
        } set: { item in
            switch item {
            case .topic(let t)?: model.open(topic: t)
            case .section(let s)?: model.section = s
            case nil: break
            }
        }
    }
}
