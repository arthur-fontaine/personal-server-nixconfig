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
                .modifier(HostedLandscapeHook())
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

/// `-hostedLandscape`: the real root view hosted at an iPhone 17 Pro's landscape size (874 × 402 pt,
/// compact width and height, its landscape safe areas, no status bar), rotated into the portrait
/// screen so a review capture shows it (design-rules 7.2: the simulator here doesn't rotate apps;
/// a real-device check comes later). Review-only; numbers are the device's, not design tokens.
struct HostedLandscapeHook: ViewModifier {
    static let on = ProcessInfo.processInfo.arguments.contains("-hostedLandscape")

    func body(content: Content) -> some View {
        if Self.on {
            GeometryReader { geo in
                content
                    .environment(\.verticalSizeClass, .compact)
                    .environment(\.horizontalSizeClass, .compact)
                    .padding(EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62))
                    .frame(width: 874, height: 402)
                    .rotationEffect(.degrees(90))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()
            .statusBarHidden()
        } else {
            content
        }
    }
}
