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

    let file: URL?
    static let limit = 150

    public init(directory: URL? = UISpecMemory.defaultDirectory) {
        file = directory?.appending(path: "ui-specs.json")
    }

    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "HermesUI")
    }

    func load() -> [MessageID: Entry] {
        guard let file, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in MessageID(k).map { ($0, v) } })
    }

    func save(_ entries: [MessageID: Entry]) {
        guard let file else { return }
        let kept = entries.sorted { $0.value.source > $1.value.source }.prefix(Self.limit)
        let out = Dictionary(uniqueKeysWithValues: kept.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(out) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
