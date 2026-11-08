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

/// What the pet shows: what Hermes is doing (protocol v3, §5), and nothing else. No needs,
/// no levels: nothing asks for care, nothing degrades when ignored.
public enum PetMood: String, Sendable, Codable, CaseIterable, Hashable {
    /// Hermes is idle.
    case idle
    /// Hermes is thinking or running a tool.
    case working
    /// A question is open for the owner.
    case waiting
    /// A short beat after a turn finished.
    case happy
    /// A short beat after a turn failed.
    case confused

    /// A mood as the backend names it. Protocol v2's needs-based moods and unknown values
    /// read as the nearest v3 one, so an older server or an old snapshot still decodes.
    public init(reported: String?) {
        switch reported?.lowercased() {
        case "working", "focused", "busy": self = .working
        case "waiting", "attentive": self = .waiting
        case "happy": self = .happy
        case "confused": self = .confused
        default: self = .idle
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(reported: try? decoder.singleValueContainer().decode(String.self))
    }

    /// The live mood. Hermes' status wins (it arrives in the same state message, and the
    /// store also hears answered questions first); a happy or confused beat shows until
    /// `until`, and one without an end (a v2 server's lasting "happy") is ignored.
    public init(agent: AgentStatus?, reported: PetMood?, until: Date?, now: Date = .now) {
        switch agent ?? .idle {
        case .thinking, .working: self = .working
        case .waitingUser: self = .waiting
        case .idle, .error:
            if let reported, reported == .happy || reported == .confused, let until, now < until {
                self = reported
            } else {
                self = .idle
            }
        }
    }

    /// The Codex row it loops.
    public var animation: PetAnimation {
        switch self {
        case .idle: .idle
        case .working: .running
        case .waiting: .waiting
        case .happy: .jumping
        case .confused: .failed
        }
    }

    public var caption: String {
        switch self {
        case .idle: L("Resting")
        case .working: L("Working")
        case .waiting: L("Waiting for you")
        case .happy: L("All done")
        case .confused: L("Something went wrong")
        }
    }

    public var symbol: String {
        switch self {
        case .idle: "moon.zzz"
        case .working: "hammer"
        case .waiting: "hand.raised"
        case .happy: "checkmark.circle"
        case .confused: "questionmark.circle"
        }
    }
}
