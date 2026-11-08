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
        List(selection: selectionBinding) {
            Section("Chats") {
                row(.main, unread: store.mainThread.unreadCount)
                ForEach(store.threads) { thread in row(thread.id, unread: thread.unreadCount) }
                Button { model.showNewSubchat = true } label: {
                    Label { Text("New Sub-chat…") } icon: { Image(systemName: "plus").accessibilityHidden(true) }
                }
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

    /// The tag outermost: the list's selection reads it from the row itself.
    private func row(_ topic: TopicID, unread: Int) -> some View {
        // The symbol is decoration: VoiceOver reads the chat's name, not "Move" or "Conversation".
        Label {
            Text(ChatTitle.name(topic, store: store))
        } icon: {
            Image(systemName: ChatTitle.symbol(topic, store: store)).accessibilityHidden(true)
        }
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
