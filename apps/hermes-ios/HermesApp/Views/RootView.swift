import HermesCore
import HermesUI
import SwiftUI

struct RootView: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            if let page = model.catalogPage {
                NavigationStack {
                    ComponentCatalog(page: page, petFrame: BundledPet.load().flatMap { SpriteSheet.cached(url: $0.spritesheet)?.frame(.idle, 0) })
                }
            } else {
                content
            }
        }
        .petAccent(model.accent)
        .animation(.smooth, value: store.auth)
        .animation(.smooth, value: store.bot)
        .fullScreenCover(isPresented: $model.callPresented) { CallView() }
        .sheet(isPresented: $model.askNotifications) { NotificationsPrompt() }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Toast(toast).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .onChange(of: scenePhase) { _, phase in
            // Private sub-chats lock again when the app leaves the screen.
            if phase == .background { model.unlockedTopics.removeAll() }
            if phase == .active { model.writeWidgetSnapshot() }
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            switch store.auth {
            case .ready:
                if store.bot != nil {
                    AppShell()
                } else {
                    FindingBotView()
                }
            case .starting:
                LaunchView()
            case .missingConfiguration(let what):
                ContentUnavailableView("Not configured", systemImage: "wrench.and.screwdriver", description: Text(what))
            default:
                LoginFlow()
            }
        }
    }
}

/// Compact width: one navigation stack, the chat is the app (no tab bar, design-rules 1.3).
/// Regular width: a split view whose sidebar lists the chats. Chosen by size class, so Slide Over
/// and narrow Stage Manager windows get the compact layout.
struct AppShell: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass == .regular {
                SplitShell()
            } else {
                NavigationStack(path: $model.path) {
                    ChatScreen(topic: model.selectedTopic ?? .main, compact: true)
                        .id(model.selectedTopic ?? .main)
                        .navigationDestination(for: AppSection.self) { section in
                            switch section {
                            case .dashboard: DashboardView()
                            case .settings: SettingsView()
                            case .chat: EmptyView()
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $model.showNewSubchat) { NewSubchatSheet() }
        .sheet(isPresented: $model.showNewPet) { NewPetSheet() }
    }
}

struct SplitShell: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .sidebarColumnWidth()
        } detail: {
            NavigationStack {
                switch model.section {
                case .chat:
                    ChatScreen(topic: model.selectedTopic ?? .main, compact: false)
                        .id(model.selectedTopic ?? .main)
                case .dashboard: DashboardView()
                case .settings: SettingsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

extension TopicID: @retroactive Identifiable {
    public var id: Int32 { self }
}
