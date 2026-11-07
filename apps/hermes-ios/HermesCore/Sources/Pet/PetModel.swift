import CoreGraphics
import Foundation

/// Codex's `pet.json` (as written by OpenAI's hatch-pet skill), plus optional fields the
/// backend may add. Unknown fields are ignored.
public struct PetManifest: Sendable, Codable, Equatable {
    public var id: String
    public var displayName: String
    public var description: String?
    public var spritesheetPath: String
    /// Atlas layout; absent means Codex v1 (8×9 cells of 192×208).
    public var columns: Int?
    public var cellWidth: Int?
    public var cellHeight: Int?
    public var version: Int?

    public init(id: String, displayName: String, description: String? = nil, spritesheetPath: String = "spritesheet.webp",
                columns: Int? = nil, cellWidth: Int? = nil, cellHeight: Int? = nil, version: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spritesheetPath = spritesheetPath
        self.columns = columns
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.version = version
    }

    enum CodingKeys: String, CodingKey { case id, displayName, name, description, spritesheetPath, columns, cellWidth, cellHeight, version }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? "pet"
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? (try? c.decode(String.self, forKey: .name)) ?? id
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        spritesheetPath = (try? c.decode(String.self, forKey: .spritesheetPath)) ?? "spritesheet.webp"
        columns = c.decodeInt64(.columns).map(Int.init)
        cellWidth = c.decodeInt64(.cellWidth).map(Int.init)
        cellHeight = c.decodeInt64(.cellHeight).map(Int.init)
        version = c.decodeInt64(.version).map(Int.init)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(spritesheetPath, forKey: .spritesheetPath)
    }

    public var layout: PetAtlasLayout {
        PetAtlasLayout(columns: columns ?? 8, cellWidth: cellWidth ?? 192, cellHeight: cellHeight ?? 208)
    }
}

public struct PetAtlasLayout: Sendable, Equatable {
    public init(columns: Int, cellWidth: Int, cellHeight: Int) {
        self.columns = columns
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }

    public var columns: Int
    public var cellWidth: Int
    public var cellHeight: Int

    public static let codex = PetAtlasLayout(columns: 8, cellWidth: 192, cellHeight: 208)

    /// Pixel rect of one frame, origin top-left.
    public func frameRect(_ animation: PetAnimation, frame: Int) -> CGRect {
        let column = frame % max(animation.frameCount, 1)
        return CGRect(x: column * cellWidth, y: animation.row * cellHeight, width: cellWidth, height: cellHeight)
    }
}

/// The nine rows of a Codex pet atlas, in order, with their frame counts.
public enum PetAnimation: String, Sendable, CaseIterable, Codable {
    case idle, runningRight = "running-right", runningLeft = "running-left", waving, jumping, failed, waiting, running, review

    public var row: Int { Self.allCases.firstIndex(of: self)! }

    public var frameCount: Int {
        switch self {
        case .idle: 6
        case .runningRight, .runningLeft: 8
        case .waving: 4
        case .jumping: 5
        case .failed: 8
        case .waiting, .running, .review: 6
        }
    }

    /// Seconds per frame: calm loops slow, activity faster.
    public var frameDuration: Double {
        switch self {
        case .idle, .waiting: 0.22
        case .review: 0.18
        case .running, .runningLeft, .runningRight: 0.11
        case .waving, .jumping: 0.12
        case .failed: 0.16
        }
    }

    /// Accepts Hermes' names (`run`, `wave`, `jump`) as well as Codex's row names.
    public init?(alias: String) {
        switch alias.lowercased() {
        case "run", "running", "work", "working": self = .running
        case "wave", "waving": self = .waving
        case "jump", "jumping": self = .jumping
        case "review", "thinking": self = .review
        case "waiting", "wait": self = .waiting
        case "failed", "fail", "error": self = .failed
        case "idle": self = .idle
        case "running-right": self = .runningRight
        case "running-left": self = .runningLeft
        default: return nil
        }
    }

    /// Plays once then returns to the mood's loop.
    public var isOneShot: Bool { self == .waving || self == .jumping }
}

/// What the pet looks like it feels, from Hermes' status and its own gauges.
public enum PetMood: String, Sendable, Codable, CaseIterable {
    case content, happy, focused, busy, attentive, sad, hungry, sleepy, asleep

    public init(agent: AgentStatus?, pet: PetState?) {
        if pet?.asleep == true { self = .asleep; return }
        // Agent activity wins over the backend's needs-based mood, which lags by up to 3 s.
        switch agent ?? .idle {
        case .thinking: self = .focused
        case .working: self = .busy
        case .waitingUser: self = .attentive
        case .error: self = .sad
        case .idle:
            // Protocol §5's order: hungry, tired, sad, happy, content.
            if let pet, pet.hunger > 0.7 { self = .hungry }
            else if let pet, pet.energy < 0.2 { self = .sleepy }
            else if let pet, pet.happiness < 0.3 { self = .sad }
            else if let pet, pet.happiness > 0.7 { self = .happy }
            else { self = .content }
        }
    }

    public var animation: PetAnimation {
        switch self {
        case .content, .happy: .idle
        case .focused: .review
        case .busy: .running
        case .attentive: .waiting
        case .sad, .hungry: .failed
        case .sleepy, .asleep: .idle
        }
    }

    /// Asleep plays the idle row slower and dimmed.
    public var speed: Double {
        switch self {
        case .asleep: 0.35
        case .sleepy: 0.6
        default: 1
        }
    }

    public var caption: String {
        switch self {
        case .content: "Content"
        case .happy: "Happy"
        case .focused: "Thinking it over"
        case .busy: "Hard at work"
        case .attentive: "Waiting for you"
        case .sad: "Something went wrong"
        case .hungry: "Hungry"
        case .sleepy: "Sleepy"
        case .asleep: "Asleep"
        }
    }

    public var symbol: String {
        switch self {
        case .content: "face.smiling"
        case .happy: "heart"
        case .focused: "brain"
        case .busy: "hammer"
        case .attentive: "hand.raised"
        case .sad: "exclamationmark.triangle"
        case .hungry: "fork.knife"
        case .sleepy: "moon"
        case .asleep: "moon.zzz"
        }
    }
}

public enum PetAction: String, Sendable, CaseIterable, Identifiable {
    case feed, play, sleep, wake

    public var id: String { rawValue }

    public var request: AppRequest {
        switch self {
        case .feed: .petFeed
        case .play: .petPlay
        case .sleep: .petSleep
        case .wake: .petWake
        }
    }

    public var title: String {
        switch self {
        case .feed: "Feed"
        case .play: "Play"
        case .sleep: "Sleep"
        case .wake: "Wake"
        }
    }

    public var symbol: String {
        switch self {
        case .feed: "fork.knife"
        case .play: "tennisball.fill"
        case .sleep: "moon.zzz.fill"
        case .wake: "sun.max.fill"
        }
    }

    /// The reaction played at once, before the backend confirms.
    public var reaction: PetAnimation {
        switch self {
        case .feed, .play: .jumping
        case .sleep: .idle
        case .wake: .waving
        }
    }

    /// The backend owns the gauges; the app shows this optimistic guess until the next state.
    public func optimisticallyApplied(to pet: PetState) -> PetState {
        var p = pet
        switch self {
        case .feed: p.hunger = max(0, p.hunger - 0.35); p.happiness = min(1, p.happiness + 0.05)
        case .play: p.happiness = min(1, p.happiness + 0.2); p.energy = max(0, p.energy - 0.1); p.hunger = min(1, p.hunger + 0.05)
        case .sleep: p.asleep = true
        case .wake: p.asleep = false
        }
        return p
    }

    public static func available(for pet: PetState) -> [PetAction] {
        pet.asleep ? [.feed, .wake] : [.feed, .play, .sleep]
    }
}
