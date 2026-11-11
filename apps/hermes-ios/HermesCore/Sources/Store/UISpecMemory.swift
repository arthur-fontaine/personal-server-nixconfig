import Foundation

/// The dynamic UIs (§8) kept across launches, as the slot ids are: the App topic's history is
/// read one page back at launch, so an older message's UI would otherwise show as text. One file
/// in Application Support, the newest `limit` kept; nil directory (tests) keeps nothing.
@MainActor
public struct UISpecMemory {
    public struct Entry: Codable, Sendable, Equatable {
        /// The App-topic message it came in (TDLib id): the newest wins.
        public var source: MessageID
        public var spec: UISpec
    }

    /// Where a UI belongs: its chat and its message's key (UIKey).
    public struct Place: Hashable, Codable, Sendable {
        public var chat: TopicID
        public var key: String

        var name: String { "\(chat)/\(key)" }

        init?(name: String) {
            let parts = name.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, let c = TopicID(parts[0]) else { return nil }
            chat = c
            key = String(parts[1])
        }

        public init(chat: TopicID, key: String) {
            self.chat = chat
            self.key = key
        }
    }

    let file: URL?
    static let limit = 150

    public init(directory: URL? = UISpecMemory.defaultDirectory) {
        // v2: by chat and key (a file of v1, by message id, never matched a message).
        file = directory?.appending(path: "ui-specs-2.json")
    }

    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "HermesUI")
    }

    func load() -> [Place: Entry] {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return Dictionary(saved.compactMap { k, v in Place(name: k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
    }

    func save(_ entries: [Place: Entry]) {
        guard let file else { return }
        let kept = entries.sorted { $0.value.source > $1.value.source }.prefix(Self.limit)
        let out = Dictionary(kept.map { ($0.key.name, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let data = try? JSONEncoder().encode(out) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
