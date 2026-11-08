import Foundation

// Protocol v2's tamagotchi, kept only so the old views compile until the designer's rewrite
// (which uses PetMood, petAnimation, petReaction and caress()) lands. Delete this file then.
// Nothing here talks to Hermes: the old values are constants and every action is a caress.

@available(*, deprecated, message: "The pet is a companion now (protocol v3): no needs, levels or actions.")
public extension PetState {
    var hunger: Double { 0 }
    var energy: Double { 1 }
    var happiness: Double { 1 }
    var xp: Int { 0 }
    var level: Int { 1 }
    var xpForNextLevel: Int? { nil }
    var asleep: Bool { false }
    var levelProgress: Double { 0 }
    static func totalXP(forLevel level: Int) -> Int { 0 }
}

@available(*, deprecated, message: "The pet is a companion now (protocol v3): use HermesStore.caress().")
public enum PetAction: String, Sendable, CaseIterable, Identifiable {
    case feed, play, sleep, wake

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String { "heart" }
    /// None: the old sheet shows no action buttons.
    public static func available(for pet: PetState) -> [PetAction] { [] }
}

@available(*, deprecated, message: "The pet is a companion now (protocol v3).")
public extension PetMood {
    static let content = PetMood.idle
    init(agent: AgentStatus?, pet: PetState?) {
        self.init(agent: agent, reported: pet?.mood, until: pet?.moodUntil)
    }
    var speed: Double { 1 }
}

@available(*, deprecated, message: "The pet is a companion now (protocol v3): use HermesStore.caress().")
public extension HermesStore {
    func perform(_ action: PetAction) async throws { caress() }
}

@available(*, deprecated, message: "The pet is a companion now (protocol v3): no needs or levels.")
public extension SharedSnapshot {
    init(petName: String, petLevel: Int, levelProgress: Double, hunger: Double, energy: Double, happiness: Double,
         asleep: Bool, mood: PetMood, agentStatus: AgentStatus, agentTask: String?, questionText: String?,
         spritesheetFile: String?, updatedAt: Date = .now) {
        self.init(petName: petName, mood: mood, agentStatus: agentStatus, agentTask: agentTask,
                  questionText: questionText, spritesheetFile: spritesheetFile, updatedAt: updatedAt)
    }
    var petLevel: Int { 1 }
    var levelProgress: Double { 0 }
    var hunger: Double { 0 }
    var energy: Double { 1 }
    var happiness: Double { 1 }
    var asleep: Bool { false }
}
