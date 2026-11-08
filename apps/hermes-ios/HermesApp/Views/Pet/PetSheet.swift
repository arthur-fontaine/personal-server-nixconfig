import HermesCore
import HermesUI
import SwiftUI

/// The pet's sheet, from the pet in the chat's toolbar (navigation A, design-rules 1.2): the pet
/// and its mood, its needs, the three actions, its level, then Dashboard and Settings. A system
/// inset-grouped list (6.3), detents and the system grabber (1.5).
struct PetSheet: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var busy: PetAction?
    @State private var showGenerate = false

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.petPath) {
            List {
                Section {
                    VGroup(alignment: .center, spacing: .xs) {
                        PetSpriteView(animation: nil, size: .hero)
                            .onTapGesture {
                                store.petReaction = .waving
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            }
                        Label(store.petMood.caption, systemImage: store.petMood.symbol).textRole(.headline)
                        AgentStatusLabel(agent: store.agent)
                    }
                    .frame(maxWidth: .infinity)
                }
                Section("Needs") {
                    need("Fullness", symbol: "fork.knife", value: 1 - (store.pet?.hunger ?? 0.3))
                    need("Energy", symbol: "bolt.fill", value: store.pet?.energy ?? 0.8)
                    need("Happiness", symbol: "heart.fill", value: store.pet?.happiness ?? 0.7)
                }
                Section {
                    ForEach(store.pet.map(PetAction.available(for:)) ?? [.feed, .play, .sleep]) { action in
                        Button { perform(action) } label: {
                            HGroup(spacing: .s) {
                                Label(action.title, systemImage: action.symbol)
                                Spacer()
                                if busy == action { ProgressView() }
                            }
                        }
                        .disabled(busy != nil || store.pet == nil)
                    }
                }
                Section("Level") {
                    Gauge(value: store.pet?.levelProgress ?? 0) {
                        Text("Level \(store.pet?.level ?? 1)")
                    } currentValueLabel: {
                        if let pet = store.pet {
                            Text("\(pet.xp) XP, \((pet.xpForNextLevel ?? PetState.totalXP(forLevel: pet.level)) - pet.xp) to the next level")
                        }
                    }
                    .gaugeStyle(.linearCapacity)
                    .accessibilityIdentifier("pet.level")
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
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showGenerate = true } label: { Label("Hatch a New Pet…", systemImage: "sparkles") }
                    } label: { Label("More", systemImage: "ellipsis") }
                }
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

    private func need(_ title: LocalizedStringKey, symbol: String, value: Double) -> some View {
        Gauge(value: value) {
            Label(title, systemImage: symbol)
        } currentValueLabel: {
            Text(value, format: .percent.precision(.fractionLength(0)))
        }
        .gaugeStyle(.linearCapacity)
        .animation(.smooth, value: value)
    }

    private func perform(_ action: PetAction) {
        busy = action
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            defer { busy = nil }
            do { try await store.perform(action) } catch { model.showToast(error.localizedDescription) }
        }
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
                    Text("Hermes draws it in a few minutes, then rebuilds the app so its icon is your new pet. Your current pet's level is kept in its history.")
                }
            }
            .navigationTitle("Hatch a Pet")
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
