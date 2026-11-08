import HermesCore
import SwiftUI

@main
struct HermesMain: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.store)
                .modifier(CompactWidthHook())
                .onOpenURL { model.open($0) }
        }
        .commands { HermesCommands(model: model) }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run()
        }
    }
}

/// Keyboard shortcuts for iPad with a keyboard (design.md, "iPad").
struct HermesCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Hermes") {
            Button("New Sub-chat") { model.showNewSubchat = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("Call Hermes") { model.startCall() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, section in
                Button(section.title) { model.select(section) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationService.shared
        NotificationService.shared.registerCategories()
        BackgroundRefresh.schedule()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in AppModel.shared.didRegisterForPush(token: deviceToken) }
    }
}

/// `-compactWidth`: the compact size class on an iPad, standing in for a narrow multitasking
/// window in design reviews (the simulator can't resize iPadOS windows from a script).
struct CompactWidthHook: ViewModifier {
    static let on = ProcessInfo.processInfo.arguments.contains("-compactWidth")
    func body(content: Content) -> some View {
        if Self.on { content.environment(\.horizontalSizeClass, .compact) } else { content }
    }
}
