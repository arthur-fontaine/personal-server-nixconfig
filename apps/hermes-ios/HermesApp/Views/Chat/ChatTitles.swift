import HermesCore
import HermesUI
import SwiftUI

/// The one place that names a chat outside itself (design-rules 1.4): a private sub-chat is
/// "Private chat" with a lock everywhere — menu, sidebar, notifications, widgets — and its real
/// name shows only as the title of the chat itself, unlocked, while the app is on screen.
/// `ChatTitleTests` and the UI tests check that the name never reaches the accessibility tree.
enum ChatTitle {
    static func name(_ topic: TopicID, store: HermesStore) -> String {
        if topic == .main { return String(localized: "Main chat") }
        if store.isPrivate(topic) { return String(localized: "Private chat") }
        return store.thread(topic)?.name ?? String(localized: "Sub-chat")
    }

    /// The open chat's own title: the real name of a private sub-chat only once unlocked and with
    /// the app active (the app switcher's snapshot is taken while inactive).
    static func title(_ topic: TopicID, store: HermesStore, unlocked: Bool, active: Bool) -> String {
        if store.isPrivate(topic), unlocked, active, let name = store.thread(topic)?.name { return name }
        return name(topic, store: store)
    }

    static func symbol(_ topic: TopicID, store: HermesStore) -> String {
        if topic == .main { return "bubble.left.and.bubble.right" }
        if store.isPrivate(topic) { return "lock.fill" }
        switch store.subchat(topic)?.preset {
        case "project": return "folder"
        case "aside": return "text.bubble"
        case "temp": return "timer"
        case "secret": return "lock.fill"
        default: return "bubble.left"
        }
    }
}

/// The chats, as the title menu lists them (iPhone): a picker, so the open chat has the system's
/// checkmark, then New Sub-chat.
struct ChatsMenu: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker(selection: Binding(get: { model.selectedTopic ?? .main }, set: { model.open(topic: $0) })) {
            Label(ChatTitle.name(.main, store: store), systemImage: ChatTitle.symbol(.main, store: store)).tag(TopicID.main)
            ForEach(store.threads) { thread in
                Label(ChatTitle.name(thread.id, store: store), systemImage: ChatTitle.symbol(thread.id, store: store))
                    .tag(thread.id)
            }
        } label: {
            Text("Chats")
        }
        .pickerStyle(.inline)
        .barMonochrome()
        Button { model.showNewSubchat = true } label: { Label("New Sub-chat", systemImage: "plus") }
            .barMonochrome()
    }
}

/// The chats in the title's menu on iPhone; none on iPad, where the sidebar lists them (an empty
/// title menu still draws its chevron).
struct ChatsTitleMenu: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.toolbarTitleMenu { ChatsMenu() }
        } else {
            content
        }
    }
}
