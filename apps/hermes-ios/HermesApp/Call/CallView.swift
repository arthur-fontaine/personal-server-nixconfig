import HermesCore
import SwiftUI

/// Full-screen call: the pet in the middle acts out the call (listening, thinking, speaking),
/// a live caption below, and the controls in one glass bar (design.md, "Call").
struct CallView: View {
    @Environment(HermesStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var session: CallSession?
    @State private var started = Date()

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.45), Color.black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.smooth(duration: 0.6), value: session?.phase)
            VStack(spacing: 24) {
                header
                Spacer()
                ZStack {
                    Circle().fill(tint.opacity(0.25)).frame(width: 260, height: 260)
                        .scaleEffect(1 + CGFloat(max(0, (session?.level ?? -60) + 50)) / 120)
                        .animation(.smooth(duration: 0.15), value: session?.level)
                    PetSpriteView(animation: animation, size: 200)
                }
                Text(phaseLabel).font(.title3.weight(.medium)).foregroundStyle(.white.opacity(dim(0.85)))
                    .contentTransition(.opacity)
                captions
                Spacer()
                controls
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .task {
            let s = CallSession(store: store)
            session = s
            started = .now
            await s.start()
        }
        .onDisappear { session?.hangUp() }
        .onChange(of: session?.phase) { _, phase in
            if case .ended(nil)? = phase { dismiss() }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(store.pet?.name ?? "Hermes").font(.title.weight(.semibold)).fontDesign(.rounded).foregroundStyle(.white)
            TimelineView(.periodic(from: started, by: 1)) { ctx in
                Text(Duration.seconds(ctx.date.timeIntervalSince(started)).formatted(.time(pattern: .minuteSecond)))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(dim(0.7)))
            }
            if let name = session?.engineName, !name.isEmpty {
                Text(name).font(.caption).foregroundStyle(.white.opacity(dim(0.5)))
            }
        }
    }

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session?.lines.suffix(6) ?? []) { line in
                        Text(line.text)
                            .font(line.fromUser ? .callout : .body)
                            .foregroundStyle(line.fromUser ? .white.opacity(dim(0.6)) : .white)
                            .frame(maxWidth: .infinity, alignment: line.fromUser ? .trailing : .leading)
                            .id(line.id)
                    }
                }
            }
            .frame(maxWidth: 600, maxHeight: 180)
            .onChange(of: session?.lines.last?.text) { if let id = session?.lines.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
        }
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: 24) {
                control(session?.muted == true ? "mic.slash.fill" : "mic.fill", label: session?.muted == true ? "Unmute" : "Mute",
                        active: session?.muted == true) { session?.muted.toggle() }
                control(session?.speaker == true ? "speaker.wave.3.fill" : "speaker.fill", label: "Speaker",
                        active: session?.speaker == true) { session?.speaker.toggle() }
                Button { session?.hangUp(); dismiss() } label: {
                    Image(systemName: "phone.down.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                }
                .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                .accessibilityLabel("End call")
            }
        }
        .padding(.bottom, 12)
    }

    private func control(_ symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2).foregroundStyle(active ? .black : .white)
                .frame(width: 72, height: 72)
        }
        .glassEffect(active ? .regular.tint(.white).interactive() : .regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    /// Increase Contrast: secondary text on the dark gradient gets nearer to white.
    private func dim(_ opacity: Double) -> Double { contrast == .increased ? min(1, opacity + 0.3) : opacity }

    private var animation: PetAnimation {
        switch session?.phase {
        case .hearing?: .waiting
        case .transcribing?, .waiting?: .review
        case .speaking?: .running
        case .ended(let e)? where e != nil: .failed
        default: .idle
        }
    }

    private var phaseLabel: String {
        switch session?.phase {
        case .starting?, nil: "Connecting…"
        case .listening?: "Listening"
        case .hearing?: "Listening…"
        case .transcribing?: "…"
        case .waiting?: "Thinking"
        case .speaking?: "Speaking"
        case .ended(let e)?: e ?? "Call ended"
        }
    }

    private var tint: Color {
        switch session?.phase {
        case .speaking?: .accentColor
        case .waiting?, .transcribing?: .indigo
        case .ended(let e)? where e != nil: .red
        default: .blue
        }
    }
}

/// Settings row: the on-device voice model, its size, download progress and delete.
struct VoiceModelRow: View {
    @State private var models = VoiceModelStore.shared
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("LFM3-Omni voice", systemImage: "waveform")
                Spacer()
                Text(status).foregroundStyle(.secondary).font(.subheadline)
            }
            switch models.state {
            case .absent, .failed:
                Button("Download (\(ByteCountFormatter.string(fromByteCount: VoiceModelStore.totalBytes, countStyle: .file)), Wi-Fi)") {
                    models.download()
                }
                if case .failed(let e) = models.state { Text(e).font(.caption).foregroundStyle(.red) }
            case .downloading(let p):
                ProgressView(value: p)
                Button("Cancel", role: .cancel) { models.cancel() }.font(.subheadline)
            case .waitingForWiFi:
                Text("Waiting for Wi-Fi…").font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { models.cancel() }.font(.subheadline)
            case .ready:
                Button("Delete Model", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("Delete the voice model? Calls will use Apple's speech until you download it again.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { models.delete() }
        }
        .onAppear { models.refresh() }
    }

    private var status: String {
        switch models.state {
        case .absent: "Not downloaded"
        case .downloading(let p): p.formatted(.percent.precision(.fractionLength(0)))
        case .waitingForWiFi: "Paused"
        case .ready: ByteCountFormatter.string(fromByteCount: models.onDiskBytes, countStyle: .file)
        case .failed: "Failed"
        }
    }
}
