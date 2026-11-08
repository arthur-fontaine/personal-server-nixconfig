import HermesCore
import SwiftUI

/// The pet, animated from its Codex atlas. `animation: nil` follows the store (Hermes' status,
/// the backend's chosen row, a one-shot reaction); a fixed animation is for login and calls.
struct PetSpriteView: View {
    @Environment(HermesStore.self) private var store: HermesStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animation: PetAnimation?
    var size: CGFloat
    var still = false

    var body: some View {
        let sheet = Self.sheet(store: store)
        let mood = store?.petMood ?? .content
        let base = animation ?? store?.pet?.animation ?? mood.animation
        let reaction = animation == nil ? store?.petReaction : nil
        let row = reaction ?? base
        let speed = animation == nil ? mood.speed : 1
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
                Image(systemName: "bird.fill").resizable().scaledToFit().foregroundStyle(.tint).padding(size * 0.2)
            }
        }
        .frame(width: size, height: size * 208 / 192)
        .opacity(animation == nil && mood == .asleep ? 0.75 : 1)
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
                Color.clear
            }
        }
    }

    private var accessibilityText: String {
        guard let pet = store?.pet else { return String(localized: "Pet") }
        return String(localized: "\(pet.name), level \(pet.level), \(store?.petMood.caption ?? "")")
    }

    static func sheet(store: HermesStore?) -> SpriteSheet? {
        if let url = store?.spriteURL, let s = SpriteSheet.cached(url: url) { return s }
        guard let bundled = BundledPet.load() else { return nil }
        return SpriteSheet.cached(url: bundled.spritesheet)
    }
}

extension PetMood {
    var tint: Color {
        switch self {
        case .content, .happy: .accentColor
        case .focused: .indigo
        case .busy: .blue
        case .attentive: .orange
        case .sad: .red
        case .hungry: .pink
        case .sleepy, .asleep: .purple
        }
    }
}

extension AgentStatus {
    var tint: Color {
        switch self {
        case .idle: .secondary
        case .thinking: .indigo
        case .working: .blue
        case .waitingUser: .accentColor
        case .error: .red
        }
    }

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

struct AgentStatusLabel: View {
    let agent: AgentState
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: agent.status.symbol)
                .symbolEffect(.pulse, isActive: agent.status.isBusy)
            Text(compact || agent.task == nil ? agent.status.label : agent.task!)
                .lineLimit(1)
        }
        .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
        .foregroundStyle(agent.status.tint)
    }
}
