import HermesCore
import SwiftUI

/// The tamagotchi: the pet large, its mood, needs, level, and the actions. Two columns when wide.
struct PetScreen: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var busy: PetAction?
    @State private var showGenerate = false

    var body: some View {
        ScrollView {
            let layout = sizeClass == .regular ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(spacing: 24))
            layout {
                stage
                VStack(spacing: 20) {
                    needs
                    actions
                    level
                }
                .frame(maxWidth: 480)
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(store.pet?.name ?? "Pet")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showGenerate = true } label: { Label("Hatch a New Pet…", systemImage: "sparkles") }
                } label: { Label("More", systemImage: "ellipsis") }
            }
        }
        .sheet(isPresented: $showGenerate) { GeneratePetSheet() }
    }

    private var stage: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [store.petMood.tint.opacity(0.35), .clear], center: .center, startRadius: 10, endRadius: 170))
                    .frame(width: 320, height: 320)
                PetSpriteView(animation: nil, size: 230)
                    .onTapGesture {
                        store.petReaction = .waving
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
            }
            Label(store.petMood.caption, systemImage: store.petMood.symbol)
                .font(.headline)
                .foregroundStyle(store.petMood.tint)
            AgentStatusLabel(agent: store.agent)
        }
        .frame(maxWidth: .infinity)
    }

    private var needs: some View {
        VStack(spacing: 14) {
            NeedBar(title: "Fullness", symbol: "fork.knife", value: 1 - (store.pet?.hunger ?? 0.3), color: .orange)
            NeedBar(title: "Energy", symbol: "bolt.fill", value: store.pet?.energy ?? 0.8, color: .yellow)
            NeedBar(title: "Happiness", symbol: "heart.fill", value: store.pet?.happiness ?? 0.7, color: .pink)
        }
        .padding(18)
        .background(.fill.quinary, in: .rect(cornerRadius: 22))
    }

    private var actions: some View {
        let available = store.pet.map(PetAction.available(for:)) ?? [.feed, .play, .sleep]
        return GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(available) { action in
                    Button { perform(action) } label: {
                        VStack(spacing: 6) {
                            if busy == action { ProgressView() } else { Image(systemName: action.symbol).font(.title2) }
                            Text(action.title).font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.glass)
                    .disabled(busy != nil || store.pet == nil)
                }
            }
        }
    }

    private var level: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 8)
                Circle().trim(from: 0, to: store.pet?.levelProgress ?? 0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(store.pet?.level ?? 1)").font(.title2.weight(.bold)).fontDesign(.rounded)
            }
            .frame(width: 64, height: 64)
            .animation(.smooth, value: store.pet?.levelProgress)
            VStack(alignment: .leading, spacing: 4) {
                Text("Level \(store.pet?.level ?? 1)").font(.headline).fontDesign(.rounded)
                if let pet = store.pet {
                    Text("\(pet.xp) xp · \((pet.xpForNextLevel ?? PetState.totalXP(forLevel: pet.level)) - pet.xp) to next level")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Grows as Hermes finishes work and you answer it.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(.fill.quinary, in: .rect(cornerRadius: 22))
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

struct NeedBar: View {
    let title: String
    let symbol: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0))).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(value < 0.25 ? Color.red.gradient : color.gradient).frame(width: geo.size.width * value)
                    }
            }
            .frame(height: 10)
            .animation(.smooth, value: value)
        }
        .accessibilityElement(children: .combine)
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
