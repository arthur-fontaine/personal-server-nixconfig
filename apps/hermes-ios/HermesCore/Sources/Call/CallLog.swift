import Foundation

/// What the last calls did, for "Copy Diagnostics" (brief item 8b: no device here, so Arthur
/// pastes this to us). Timestamped lines, the newest 400, kept across launches. No audio, and no
/// transcript beyond its length: the diagnostics may be pasted anywhere.
public final class CallLog: @unchecked Sendable {
    public static let shared = CallLog()
    static let limit = 400
    static let defaultsKey = "hermes.callLog"

    private let lock = NSLock()
    private var lines: [String]
    private let defaults: UserDefaults
    private var unsaved = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lines = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    public func log(_ message: String, at date: Date = .now) {
        let stamp = date.formatted(.iso8601.time(includingFractionalSeconds: true))
        lock.withLock {
            lines.append("\(stamp) \(message)")
            if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
            unsaved += 1
            if unsaved >= 20 { saveLocked() }
        }
    }

    public var recent: [String] { lock.withLock { lines } }

    /// Writes what isn't saved yet (call ends, the app leaves the foreground).
    public func save() { lock.withLock { saveLocked() } }

    public func clear() {
        lock.withLock {
            lines = []
            saveLocked()
        }
    }

    private func saveLocked() {
        defaults.set(lines, forKey: Self.defaultsKey)
        unsaved = 0
    }
}
