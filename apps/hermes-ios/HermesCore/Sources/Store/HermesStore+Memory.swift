import Foundation

/// What the session has read of Hermes' memory: a line's halves and messages, by (chat, first, n).
/// A line's past never changes, so they are kept until logout; the view is not (it moves with
/// every turn), nor halves still waiting for their summary.
public struct MemoryCache: Sendable {
    public struct Key: Hashable, Sendable {
        public var chat: TopicID
        public var first: Int
        public var n: Int
    }

    enum Entry: Sendable {
        case lines([MemoryLine])
        case message(MemoryMessage)
    }

    var entries: [Key: Entry] = [:]
    public var count: Int { entries.count }
}

extension HermesStore {
    /// The main chat's memory, then each sub-chat's (protocol §4.1).
    public func memoryVolumes() async throws -> [MemoryVolume] {
        try MemoryReply.volumes(try await sendRequest(.memoryVolumes))
    }

    /// One page of what Hermes sees now of that chat's memory, oldest first.
    public func memoryView(chat: TopicID, after: Int? = nil) async throws -> MemoryPage {
        try MemoryReply.page(try await sendRequest(.memoryView(chat: chat, after: after)))
    }

    /// The two halves of a line of more than one message.
    public func memoryHalves(chat: TopicID, of line: MemoryLine) async throws -> [MemoryLine] {
        let key = MemoryCache.Key(chat: chat, first: line.first, n: line.n)
        if case .lines(let lines)? = memoryCache.entries[key] { return lines }
        let lines = try MemoryReply.page(try await sendRequest(.memoryLine(chat: chat, first: line.first, n: line.n))).lines
        if !lines.isEmpty, lines.allSatisfy(\.built) { memoryCache.entries[key] = .lines(lines) }
        return lines
    }

    /// Message `index` of that chat's log.
    public func memoryMessage(chat: TopicID, index: Int) async throws -> MemoryMessage {
        let key = MemoryCache.Key(chat: chat, first: index, n: 1)
        if case .message(let message)? = memoryCache.entries[key] { return message }
        let message = try MemoryReply.message(try await sendRequest(.memoryLine(chat: chat, first: index, n: 1)))
        memoryCache.entries[key] = .message(message)
        return message
    }

    /// Forgets what was read of a chat's memory (a private one locked again), or of all of them.
    public func forgetMemory(chat: TopicID? = nil) {
        if let chat { memoryCache.entries = memoryCache.entries.filter { $0.key.chat != chat } }
        else { memoryCache.entries = [:] }
    }
}
