import HermesCore
import HermesUI
import SwiftUI

/// Asked once after login, with a word on why (design.md, "Install → first message").
struct NotificationsPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OnboardingPage(title: Text("Don't miss Hermes' questions"),
                       message: Text("Hermes asks before anything risky, and tells you when long work is done. With AirPods, Siri can read it out.")) {
            PetSpriteView(animation: .waiting, size: .hero)
        } fields: {
            EmptyView()
        } actions: {
            PrimaryButton("Turn On Notifications", fullWidth: true) {
                Task {
                    await NotificationService.shared.requestAuthorization()
                    model.askNotifications = false
                    dismiss()
                }
            }
            Button("Not Now") { model.askNotifications = false; dismiss() }
        }
        .presentationDetents([.large])
    }
}

struct LaunchView: View {
    var body: some View {
        PetSpriteView(animation: .idle, size: .stage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Looking for the bot after login; if it can't be found, why, and Try Again.
struct FindingBotView: View {
    @Environment(HermesStore.self) private var store

    var body: some View {
        if let error = store.botError {
            OnboardingPage(title: Text("Couldn't reach Hermes"), message: Text(error)) {
                PetSpriteView(animation: .failed, size: .hero)
            } fields: {
                EmptyView()
            } actions: {
                PrimaryButton("Try Again", fullWidth: true) { store.retryConnectBot() }
            }
        } else {
            OnboardingPage(title: Text("Finding Hermes"), message: Text("@\(store.config.botUsername)")) {
                PetSpriteView(animation: .jumping, size: .hero)
            } fields: {
                ProgressView()
            } actions: {
                EmptyView()
            }
        }
    }
}
