import HermesCore
import HermesUI
import SwiftUI

/// Full-screen call, as the Phone app's: the pet's name and the duration on top, the pet in the
/// middle acting out the call (listening, thinking, speaking), a live caption, and the controls in
/// one row of glass circles. Dark, without decoration: the pet carries the state.
struct CallView: View {
    @Environment(HermesStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var session: CallSession?
    @State private var started = Date()

    var body: some View {
        VGroup(alignment: .center, spacing: .l) {
            header
            Spacer()
            PetSpriteView(animation: animation, size: .stage)
            Text(phaseLabel).textRole(.headline).tone(.secondary)
                .contentTransition(.opacity)
            captions
            Spacer()
            CallControls {
                CallButton(session?.muted == true ? Text("Unmute") : Text("Mute"),
                           systemImage: session?.muted == true ? "mic.slash.fill" : "mic.fill",
                           kind: .toggle(isOn: session?.muted == true)) { session?.muted.toggle() }
                CallButton(Text("Speaker"), systemImage: session?.speaker == true ? "speaker.wave.3.fill" : "speaker.fill",
                           kind: .toggle(isOn: session?.speaker == true)) { session?.speaker.toggle() }
                CallButton(Text("End"), systemImage: "phone.down.fill", kind: .end) { session?.hangUp(); dismiss() }
            }
        }
        .frame(maxWidth: .infinity)
        .inset(.vertical, .xl)
        .scenePaddingHorizontal()
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
        VGroup(alignment: .center, spacing: .xxs) {
            Text(store.pet?.name ?? "Hermes").textRole(.title)
            TimelineView(.periodic(from: started, by: 1)) { ctx in
                Text(Duration.seconds(ctx.date.timeIntervalSince(started)).formatted(.time(pattern: .minuteSecond)))
                    .textRole(.subheadline).monospacedDigit().tone(.secondary)
            }
            if let name = session?.engineName, !name.isEmpty {
                Text(name).textRole(.caption).tone(.tertiary)
            }
        }
    }

    /// The last lines said: Hermes' in the label colour, the owner's secondary and trailing.
    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VGroup(spacing: .s) {
                    ForEach(session?.lines.suffix(6) ?? []) { line in
                        Text(line.text)
                            .textRole(line.fromUser ? .subheadline : .body)
                            .tone(line.fromUser ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: line.fromUser ? .trailing : .leading)
                            .id(line.id)
                    }
                }
            }
            .captionArea()
            .onChange(of: session?.lines.last?.text) { if let id = session?.lines.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
        }
    }

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
        case .starting?, nil: String(localized: "Connecting…")
        case .listening?: String(localized: "Listening")
        case .hearing?: String(localized: "Listening…")
        case .transcribing?: "…"
        case .waiting?: String(localized: "Thinking")
        case .speaking?: String(localized: "Speaking")
        case .ended(let e)?: e ?? String(localized: "Call ended")
        }
    }
}

/// Settings row: the on-device voice model, its size, download progress and delete.
struct VoiceModelRow: View {
    @State private var models = VoiceModelStore.shared
    @State private var confirmDelete = false

    var body: some View {
        VGroup(spacing: .xs) {
            LabeledContent { Text(status) } label: { Label("LFM3-Omni voice", systemImage: "waveform") }
            switch models.state {
            case .absent, .failed:
                ListActionRow(Text("Download (\(ByteCountFormatter.string(fromByteCount: VoiceModelStore.totalBytes, countStyle: .file)), Wi-Fi)"),
                              detail: nil, systemImage: "arrow.down.circle") { models.download() }
                if case .failed(let e) = models.state { Text(e).textRole(.caption).tone(.destructive) }
            case .downloading(let p):
                ProgressView(value: p)
                ListActionRow(Text("Cancel"), detail: nil, systemImage: "xmark") { models.cancel() }
            case .waitingForWiFi:
                Text("Waiting for Wi-Fi…").textRole(.caption).tone(.secondary)
                ListActionRow(Text("Cancel"), detail: nil, systemImage: "xmark") { models.cancel() }
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
        case .absent: String(localized: "Not downloaded")
        case .downloading(let p): p.formatted(.percent.precision(.fractionLength(0)))
        case .waitingForWiFi: String(localized: "Paused")
        case .ready: ByteCountFormatter.string(fromByteCount: models.onDiskBytes, countStyle: .file)
        case .failed: String(localized: "Failed")
        }
    }
}
