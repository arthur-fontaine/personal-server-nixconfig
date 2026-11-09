import Foundation

/// What the App topic last did, shown in Settings › About › Diagnostics: when each slot last
/// decoded, and the last errors. Without it a frozen state looks like an idle Hermes.
public struct AppTopicLog: Sendable, Equatable {
    public struct Slot: Sendable, Equatable {
        public var messageID: Int64
        public var at: Date
    }

    public private(set) var slots: [String: Slot] = [:]
    public private(set) var lines: [String] = []
    public private(set) var lastError: (String)?
    public private(set) var lastErrorAt: Date?

    public init() {}

    mutating func decoded(_ slot: String, id: Int64, at: Date = .now) {
        slots[slot] = Slot(messageID: id, at: at)
    }

    mutating func note(_ line: String, at: Date = .now) {
        lines.append("\(Self.time(at)) \(line)")
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
    }

    mutating func fail(_ error: String, at: Date = .now) {
        lastError = error
        lastErrorAt = at
        note("error: " + error, at: at)
    }

    /// The Diagnostics paragraph.
    public var summary: [String] {
        var out = ["App topic slots:"]
        for name in ["state", "stats", "controls", "devices"] {
            if let s = slots[name] { out.append("  \(name) #\(s.messageID) decoded at \(Self.time(s.at))") }
            else { out.append("  \(name): never decoded") }
        }
        out.append("Last App topic error: " + (lastError.map { "\($0) at \(Self.time(lastErrorAt ?? .now))" } ?? "none"))
        out.append("App topic log:")
        out += lines.suffix(20).map { "  " + $0 }
        return out
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

/// The slot messages' Bot API ids, kept across launches: the slots are edited in place, so a
/// launch can read them by id before (or without) the topic's history.
@MainActor
public struct SlotMemory {
    let defaults: UserDefaults?
    static let key = "appTopicSlots"

    public init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

    func load(topic: TopicID) -> [Int64] {
        guard let saved = defaults?.dictionary(forKey: Self.key), saved["topic"] as? Int == Int(topic) else { return [] }
        return (saved["ids"] as? [Int] ?? []).map(Int64.init)
    }

    func save(topic: TopicID, ids: [Int64]) {
        defaults?.set(["topic": Int(topic), "ids": ids.sorted().map(Int.init)], forKey: Self.key)
    }
}
