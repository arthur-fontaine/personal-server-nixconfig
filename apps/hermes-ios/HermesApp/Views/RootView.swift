import HermesCore
import SwiftUI

struct RootView: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
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
        .animation(.smooth, value: store.auth)
        .animation(.smooth, value: store.bot)
        .fullScreenCover(isPresented: $model.callPresented) { CallView() }
        .sheet(isPresented: $model.askNotifications) { NotificationsPrompt() }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .onChange(of: scenePhase) { _, phase in
            // Private sub-chats lock again when the app leaves the screen.
            if phase == .background { model.unlockedTopics.removeAll() }
            if phase == .active { model.writeWidgetSnapshot() }
        }
    }
}

struct NotificationsPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            PetSpriteView(animation: .waiting, size: 110)
            Text("Don't miss Hermes' questions").font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text("Hermes asks before anything risky, and tells you when long work is done. With AirPods, Siri can read it out.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button {
                Task {
                    await NotificationService.shared.requestAuthorization()
                    model.askNotifications = false
                    dismiss()
                }
            } label: { Text("Turn On Notifications").font(.headline).frame(maxWidth: .infinity, minHeight: 34) }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Button("Not Now") { model.askNotifications = false; dismiss() }
        }
        .padding(28)
        .presentationDetents([.medium])
    }
}

struct LaunchView: View {
    var body: some View {
        PetSpriteView(animation: .idle, size: 120)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FindingBotView: View {
    @Environment(HermesStore.self) private var store

    var body: some View {
        VStack(spacing: 20) {
            PetSpriteView(animation: store.botError == nil ? .jumping : .failed, size: 140)
            if let error = store.botError {
                Text("Couldn't reach Hermes").font(.title2.weight(.semibold))
                Text(error).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { store.retryConnectBot() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            } else {
                Text("Finding @\(store.config.botUsername)…").font(.headline).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: 440)
    }
}

/// iPhone (compact width): tabs. iPad and wide windows: a split view. Chosen by size class, so an
/// iPad in Slide Over or a narrow Stage Manager window gets the iPhone layout.
struct AppShell: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if sizeClass == .regular {
                SplitShell()
            } else {
                TabShell()
            }
        }
        .sheet(isPresented: $model.showNewSubchat) { NewSubchatSheet() }
    }
}

struct TabShell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.section) {
            Tab(AppSection.chat.title, systemImage: AppSection.chat.symbol, value: .chat) {
                NavigationStack { CompactChatRoot() }
            }
            Tab(AppSection.pet.title, systemImage: AppSection.pet.symbol, value: .pet) {
                NavigationStack { PetScreen() }
            }
            Tab(AppSection.dashboard.title, systemImage: AppSection.dashboard.symbol, value: .dashboard) {
                NavigationStack { DashboardView() }
            }
            Tab(AppSection.settings.title, systemImage: AppSection.settings.symbol, value: .settings) {
                NavigationStack { SettingsView() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

/// The chat tab on iPhone: the main chat is the root (the daily case); sub-chats come from the
/// title menu and push.
struct CompactChatRoot: View {
    @Environment(AppModel.self) private var model
    @State private var showSubchats = false

    var body: some View {
        @Bindable var model = model
        ChatView(topic: .main)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSubchats = true } label: {
                        Label("Sub-chats", systemImage: "list.bullet")
                    }
                }
            }
            .sheet(isPresented: $showSubchats) {
                NavigationStack {
                    ThreadList(selection: Binding(get: { nil }, set: { topic in
                        showSubchats = false
                        if let topic, topic != .main { model.selectedTopic = topic; pushed = topic }
                    }))
                    .navigationTitle("Chats")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showSubchats = false } }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .navigationDestination(item: $pushed) { topic in ChatView(topic: topic) }
            .onAppear {
                if let t = model.selectedTopic, t != .main, pushed == nil { pushed = t }
            }
            .onChange(of: model.selectedTopic) { _, t in
                if let t, t != .main { pushed = t }
            }
    }

    @State private var pushed: TopicID?
}

extension TopicID: @retroactive Identifiable {
    public var id: Int32 { self }
}

struct SplitShell: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            NavigationStack {
                switch model.section {
                case .chat: ChatView(topic: model.selectedTopic ?? .main).id(model.selectedTopic)
                case .pet: PetScreen()
                case .dashboard: DashboardView()
                case .settings: SettingsView()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
