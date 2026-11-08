import HermesCore
import HermesUI
import SwiftUI

/// The pet's sheet, from the pet in the bar (design-rules 11.4): the pet large — stroke or hold
/// it to caress it —, what Hermes is doing in one sentence, New Pet…, then Dashboard and
/// Settings. A companion, not a Tamagotchi: no needs, no stats, nothing to do.
struct PetSheet: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showGenerate = false

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.petPath) {
            List {
                Section {
                    VGroup(alignment: .center, spacing: .s) {
                        PetSpriteView(animation: nil, size: .stage)
                            .caressable(trigger: store.caressedAt) { store.caress() }
                        Text(sentence)
                            .textRole(.body)
                            .tone(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("pet.sentence")
                    }
                    .frame(maxWidth: .infinity)
                }
                Section {
                    Button { showGenerate = true } label: { Label("New Pet…", systemImage: "sparkles") }
                }
                Section {
                    NavigationLink(value: AppSection.dashboard) { Label(AppSection.dashboard.title, systemImage: AppSection.dashboard.symbol) }
                    NavigationLink(value: AppSection.settings) { Label(AppSection.settings.title, systemImage: AppSection.settings.symbol) }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(store.pet?.name ?? String(localized: "Pet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() }.barMonochrome() }
            }
            .navigationDestination(for: AppSection.self) { section in
                switch section {
                case .dashboard: DashboardView()
                case .settings: SettingsView()
                default: EmptyView()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showGenerate) { GeneratePetSheet() }
    }

    /// What Hermes is doing, in one sentence: its task while it works, else the pet's mood.
    private var sentence: String {
        if store.agent.status != .idle, let task = store.agent.task { return task }
        return store.petMood.caption
    }
}

struct GeneratePetSheet: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("A tiny owl with a messenger bag", text: $prompt, axis: .vertical).lineLimit(3...6)
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("Hermes draws it in a few minutes, then rebuilds the app so its icon is your new pet.")
                }
            }
            .navigationTitle("New Pet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hatch") {
                        var req = AppRequest.petGenerate(prompt: prompt)
                        if !name.isEmpty { req.payload["name"] = .string(name) }
                        Task {
                            do {
                                _ = try await store.sendRequest(req)
                                model.showToast("Hermes is hatching your pet")
                            } catch { model.showToast(error.localizedDescription) }
                        }
                        dismiss()
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
