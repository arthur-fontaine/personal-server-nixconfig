import HermesCore
import HermesUI
import SwiftUI

/// The pet, animated from its Codex atlas. `animation: nil` follows the store (Hermes' status,
/// the backend's chosen row, a one-shot reaction); a fixed animation is for login and calls.
struct PetSpriteView: View {
    @Environment(HermesStore.self) private var store: HermesStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animation: PetAnimation?
    var size: PetSize
    var still = false

    var body: some View {
        PetAvatar(size) { sprite }
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("pet.avatar")
    }

    @ViewBuilder private var sprite: some View {
        let sheet = Self.sheet(store: store)
        // The store picks the row: a one-shot reaction, else what Hermes is doing (11.2).
        let row = animation ?? store?.petAnimation ?? .idle
        let reaction = animation == nil ? store?.petReaction : nil
        let speed = 1.0
        Group {
            if let sheet {
                if still || reduceMotion {
                    frameImage(sheet, row, 0)
                } else {
                    TimelineView(.animation(minimumInterval: row.frameDuration / speed)) { context in
                        frameImage(sheet, row, frameIndex(context.date, row: row, speed: speed))
                    }
                }
            } else {
                Image(systemName: "bird.fill").resizable().scaledToFit().tone(.accent)
            }
        }
        .task(id: reaction) {
            // A reaction plays its row once, then the mood's loop resumes.
            guard let reaction, reaction.isOneShot || reaction == .idle else { return }
            try? await Task.sleep(for: .seconds(reaction.frameDuration * Double(reaction.frameCount) * 2))
            if store?.petReaction == reaction { store?.petReaction = nil }
        }
        .accessibilityLabel(accessibilityText)
    }

    private func frameIndex(_ date: Date, row: PetAnimation, speed: Double) -> Int {
        Int(date.timeIntervalSinceReferenceDate * speed / row.frameDuration) % row.frameCount
    }

    private func frameImage(_ sheet: SpriteSheet, _ row: PetAnimation, _ index: Int) -> some View {
        Group {
            if let cg = sheet.frame(row, index) {
                Image(decorative: cg, scale: 1).resizable().interpolation(.none).scaledToFit()
            } else {
                EmptyView()
            }
        }
    }

    private var accessibilityText: String {
        guard let pet = store?.pet else { return String(localized: "Pet") }
        return String(localized: "\(pet.name), \(store?.petMood.caption ?? "")")
    }

    static func sheet(store: HermesStore?) -> SpriteSheet? {
        if let url = store?.spriteURL, let s = SpriteSheet.cached(url: url) { return s }
        guard let bundled = BundledPet.load() else { return nil }
        return SpriteSheet.cached(url: bundled.spritesheet)
    }
}

extension AgentStatus {
    var symbol: String {
        switch self {
        case .idle: "moon.zzz"
        case .thinking: "brain"
        case .working: "hammer.fill"
        case .waitingUser: "hand.raised.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

/// Hermes' status in words with its symbol; secondary, as Apple's subtitles (colour is kept for
/// actions, design-rules 4.2).
struct AgentStatusLabel: View {
    let agent: AgentState
    var compact = false

    var body: some View {
        Label {
            Text(compact || agent.task == nil ? agent.status.label : agent.task!)
        } icon: {
            Image(systemName: agent.status.symbol)
                .symbolEffect(.pulse, isActive: agent.status.isBusy)
        }
        .textRole(compact ? .caption : .subheadline)
        .tone(.secondary)
    }
}
