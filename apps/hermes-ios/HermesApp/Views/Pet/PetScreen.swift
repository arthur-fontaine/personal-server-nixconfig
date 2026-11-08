import HermesCore
import SwiftUI

/// The tamagotchi: the pet large, its mood, needs, level, and the actions. Two columns when wide.
struct PetScreen: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var busy: PetAction?
    @State private var showGenerate = false

    var body: some View {
        ScrollView {
            let wide = sizeClass == .regular || verticalSizeClass == .compact
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(spacing: 24))
            layout {
                stage
                VStack(spacing: 20) {
                    needs
                    actions
                    level
                }
                .frame(minWidth: wide ? 320 : nil, maxWidth: 480)
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
                    .frame(width: stageSize + 90, height: stageSize + 90)
                PetSpriteView(animation: nil, size: stageSize)
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

    private var stageSize: CGFloat { verticalSizeClass == .compact ? 150 : 230 }

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
        // In the scrolling content: bordered buttons; glass stays on the bars above it.
        return HStack(spacing: 12) {
            ForEach(available) { action in
                Button { perform(action) } label: {
                    VStack(spacing: 6) {
                        if busy == action { ProgressView() } else { Image(systemName: action.symbol).font(.title2) }
                        Text(action.title).font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 18))
                .disabled(busy != nil || store.pet == nil)
            }
        }
    }

    private var level: some View {
        HStack(spacing: 16) {
            Gauge(value: store.pet?.levelProgress ?? 0) {
                EmptyView()
            } currentValueLabel: {
                Text(store.pet?.level ?? 1, format: .number).fontWeight(.bold).fontDesign(.rounded)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.accentColor)
            .animation(.smooth, value: store.pet?.levelProgress)
            .accessibilityHidden(true)
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
            Gauge(value: value) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(value < 0.25 ? Color.red : color)
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
