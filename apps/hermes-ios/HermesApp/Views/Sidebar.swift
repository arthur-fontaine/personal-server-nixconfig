import HermesCore
import HermesUI
import SwiftUI

/// iPad sidebar (regular width): the chats, then Dashboard and Settings at its foot (the pet is
/// the detail's bar item, as on iPhone). System sidebar rows; names through `ChatTitle`, so a private
/// sub-chat is "Private chat" here too (design-rules 1.4).
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(HermesStore.self) private var store

    var body: some View {
        List(selection: selectionBinding) {
            Section("Chats") {
                row(.main, unread: store.mainThread.unreadCount)
                ForEach(store.threads) { thread in row(thread.id, unread: thread.unreadCount) }
                Button { model.showNewSubchat = true } label: { Label("New Sub-chat…", systemImage: "plus") }
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
            case .chat: .topic(model.selectedTopic ?? .main)
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
