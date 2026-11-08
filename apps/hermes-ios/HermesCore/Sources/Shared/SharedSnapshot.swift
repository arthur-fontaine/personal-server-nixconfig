import Foundation

/// What the widgets show, written by the app into the App Group container (widgets can't run
/// TDLib). The spritesheet is copied next to it.
public struct SharedSnapshot: Codable, Sendable, Equatable {
    public var petName: String
    public var mood: PetMood
    public var agentStatus: AgentStatus
    public var agentTask: String?
    public var questionText: String?
    public var spritesheetFile: String?
    public var updatedAt: Date

    public init(petName: String, mood: PetMood, agentStatus: AgentStatus, agentTask: String?, questionText: String?,
                spritesheetFile: String?, updatedAt: Date = .now) {
        self.petName = petName
        self.mood = mood
        self.agentStatus = agentStatus
        self.agentTask = agentTask
        self.questionText = questionText
        self.spritesheetFile = spritesheetFile
        self.updatedAt = updatedAt
    }

    public static let placeholder = SharedSnapshot(
        petName: "Pip", mood: .idle, agentStatus: .idle, agentTask: nil, questionText: nil, spritesheetFile: nil)
}

public enum SharedContainer {
    public static func url(group: String?) -> URL? {
        guard let group else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    private static func snapshotURL(group: String?) -> URL? { url(group: group)?.appending(path: "snapshot.json") }

    public static func write(_ snapshot: SharedSnapshot, group: String?) {
        guard let file = snapshotURL(group: group), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public static func read(group: String?) -> SharedSnapshot? {
        guard let file = snapshotURL(group: group), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SharedSnapshot.self, from: data)
    }

    /// Copies the spritesheet into the group, named by pet version, and returns the file name.
    public static func storeSpritesheet(_ source: URL, petID: String, version: Int, group: String?) -> String? {
        guard let dir = url(group: group) else { return nil }
        let name = "sprite-\(petID)-v\(version).\(source.pathExtension.isEmpty ? "webp" : source.pathExtension)"
        let dest = dir.appending(path: name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            // Older versions go: one sheet is ~1 MB, and the group is shared with the widget.
            for old in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix("sprite-") {
                try? FileManager.default.removeItem(at: dir.appending(path: old))
            }
            try? FileManager.default.copyItem(at: source, to: dest)
        }
        return name
    }

    public static func spritesheet(named name: String?, group: String?) -> URL? {
        guard let name, let dir = url(group: group) else { return nil }
        let u = dir.appending(path: name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}
