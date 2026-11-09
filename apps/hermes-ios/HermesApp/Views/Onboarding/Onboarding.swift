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
            SecondaryButton("Not Now", fullWidth: true) { model.askNotifications = false; dismiss() }
        }
        .presentationDetents([.large])
    }
}

struct LaunchView: View {
    @Environment(HermesStore.self) private var store
    /// The sheet decoded and the pet's centring measured, off the main actor: until then, the
    /// launch is the system's plain launch background, and the pet appears ready to animate.
    @State private var prepared = false

    var body: some View {
        ZStack {
            if prepared {
                PetSpriteView(animation: .idle, size: .stage)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth, value: prepared)
        .task {
            let url = store.spriteURL ?? BundledPet.load()?.spritesheet
            let id = store.pet?.id ?? "pip", version = store.pet?.version ?? 0
            await Task.detached(priority: .userInitiated) {
                guard let url, let sheet = SpriteSheet.cached(url: url) else { return }
                _ = PetSpriteView.centering(sheet: sheet, petID: id, version: version, stills: false)
            }.value
            prepared = true
        }
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
