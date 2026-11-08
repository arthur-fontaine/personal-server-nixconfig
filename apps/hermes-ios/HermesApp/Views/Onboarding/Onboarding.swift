import HermesCore
import HermesUI
import SwiftUI

// Phase 2 of the redesign: these screens still use raw styling (DesignCheck lists the file).

struct NotificationsPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            PetSpriteView(animation: .waiting, size: .hero)
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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Not Now") { model.askNotifications = false; dismiss() }
        }
        .padding(28)
        .presentationDetents([.medium])
    }
}

struct LaunchView: View {
    var body: some View {
        PetSpriteView(animation: .idle, size: .stage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FindingBotView: View {
    @Environment(HermesStore.self) private var store

    var body: some View {
        VStack(spacing: 20) {
            PetSpriteView(animation: store.botError == nil ? .jumping : .failed, size: .stage)
            if let error = store.botError {
                Text("Couldn't reach Hermes").font(.title2.weight(.semibold))
                Text(error).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { store.retryConnectBot() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Text("Finding @\(store.config.botUsername)…").font(.headline).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: 440)
    }
}

