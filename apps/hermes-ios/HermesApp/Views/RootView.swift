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
            if model.widgetGallery {
                // In a stack with an inline title: scrolled content goes under the bar's edge
                // effect, not under the status bar (round 6's U2).
                NavigationStack { WidgetGallery(sprite: model.writeWidgetStills()).navigationTitle(Text(verbatim: "Widgets")) }
            } else if let page = model.catalogPage {
                NavigationStack {
                    ComponentCatalog(page: page, petFrame: BundledPet.load().flatMap { SpriteSheet.cached(url: $0.spritesheet)?.frame(.idle, 0) })
                }
            } else {
                content
            }
        }
        .petAccent(model.accent)
        .reviewReducedMotion(model.reduceMotion)
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
            model.scenePhaseChanged(phase)
        }
    }

    /// The launch screen stays until the chat can show: Telegram ready and the bot found, in one
    /// fade. "Finding Hermes" only when the search takes a while or fails (it flashed between the
    /// launch and the chat, a fade in two steps).
    @State private var findingIsSlow = false
    static let findingShownAfter: Duration = .seconds(3)

    private enum Screen: Equatable { case launch, finding, app, other }

    private var screen: Screen {
        switch store.auth {
        case .starting: .launch
        case .ready where store.bot != nil: .app
        case .ready: store.botError != nil || findingIsSlow ? .finding : .launch
        default: .other
        }
    }

    private var content: some View {
        screenView
            .transition(.opacity)
            .id(screen)
            .animation(.smooth, value: screen)
            .task(id: store.auth == .ready && store.bot == nil) {
                guard store.auth == .ready, store.bot == nil else { findingIsSlow = false; return }
                try? await Task.sleep(for: Self.findingShownAfter)
                findingIsSlow = !Task.isCancelled
            }
    }

    /// One view per screen, the launch's the same one from Telegram starting to the bot found.
    @ViewBuilder private var screenView: some View {
        switch screen {
        case .launch: LaunchView()
        case .finding: FindingBotView()
        case .app: AppShell()
        case .other:
            if case .missingConfiguration(let what) = store.auth {
                ContentUnavailableView("Not configured", systemImage: "wrench.and.screwdriver", description: Text(what))
            } else {
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
