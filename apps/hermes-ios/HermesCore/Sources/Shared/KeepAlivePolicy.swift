import Foundation

/// When the app stays running in the background on a free team (no APNs; brief item 9, decided by
/// the orchestrator): while Hermes works, a question waits, a call is on, or for a grace window
/// after Hermes' last activity. Otherwise iOS suspends it and background refresh is all there is.
public enum KeepAlivePolicy {
    public static let defaultGrace: TimeInterval = 10 * 60
    public static let graceChoices: [TimeInterval] = [5 * 60, 10 * 60, 20 * 60, 30 * 60]
    public static let defaultsKey = "hermes.keepAliveGrace"

    public static func stayAlive(agent: AgentStatus, questions: Int, call: Bool, lastActivity: Date?,
                                 now: Date = .now, grace: TimeInterval = defaultGrace) -> Bool {
        if call || questions > 0 { return true }
        if agent == .thinking || agent == .working || agent == .waitingUser { return true }
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) < grace
    }

    /// The grace window chosen in Settings.
    public static func grace(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let v = defaults.double(forKey: defaultsKey)
        return v > 0 ? v : defaultGrace
    }

    /// How long a Live Activity's content holds before iOS shows it as stale: renewed every minute
    /// while the app is connected, so it goes stale only when no one can update it.
    public static let liveActivityStale: TimeInterval = 2 * 60
}

/// Notifications already posted, by the message they are about: a notify seen live and again
/// in a history replay (a relaunch by background refresh) is posted once.
public final class PostedNotifications: @unchecked Sendable {
    public static let shared = PostedNotifications()
    static let limit = 300
    static let defaultsKey = "hermes.postedNotifications"
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var keys: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// True the first time for a key (and records it).
    public func claim(_ key: String) -> Bool {
        lock.withLock {
            guard !keys.contains(key) else { return false }
            keys.append(key)
            if keys.count > Self.limit { keys.removeFirst(keys.count - Self.limit) }
            defaults.set(keys, forKey: Self.defaultsKey)
            return true
        }
    }
}
