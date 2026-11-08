import HermesCore
import HermesUI
import SwiftUI

/// iPad sidebar (regular width): the chats, and Dashboard and Settings pinned at its foot (the
/// pet is the detail's bar item, as on iPhone). System sidebar rows; names through `ChatTitle`, so a private
/// sub-chat is "Private chat" here too (design-rules 1.4).
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(HermesStore.self) private var store

    var body: some View {
        List {
            Section("Chats") {
                row(.main, unread: store.mainThread.unreadCount)
                ForEach(store.threads) { thread in row(thread.id, unread: thread.unreadCount) }
                ListActionRow(Text("New Sub-chat…"), detail: nil, systemImage: "plus") { model.showNewSubchat = true }
            }
        }
        .listStyle(.sidebar)
        // Pinned to the sidebar's foot (design-rules 11.4).
        .safeAreaBar(edge: .bottom) {
            SidebarFooter {
                ForEach([AppSection.dashboard, .settings]) { s in
                    SidebarFooterRow(Text(s.title), systemImage: s.symbol, selected: model.section == s) { model.show(s) }
                        .accessibilityIdentifier("sidebar.\(s.rawValue)")
                }
            }
        }
    }

    /// A chat: its public name (a private one is "Private chat"), selected with the pet's light tint.
    private func row(_ topic: TopicID, unread: Int) -> some View {
        SidebarRow(Text(ChatTitle.name(topic, store: store)), systemImage: ChatTitle.symbol(topic, store: store),
                   selected: model.section == .chat && (model.selectedTopic ?? .main) == topic) {
            model.open(topic: topic)
        } badge: {
            UnreadBadge(unread > 0 ? Text(unread, format: .number) : nil)
        }
        .accessibilityIdentifier("sidebar.chat.\(topic)")
    }

}
