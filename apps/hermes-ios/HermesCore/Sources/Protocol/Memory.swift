import Foundation

// Hermes' memory, read-only (docs/app-protocol.md §4.1): unii's volumes, each a log of messages and
// a binary tree of one-line summaries. A line covers `n` messages (a power of 2) from `first`.

/// One chat's memory, as `memory.volumes` lists it.
public struct MemoryVolume: Sendable, Equatable, Identifiable, Decodable {
    /// The chat it belongs to: `.main`, or a sub-chat's topic.
    public var chat: TopicID
    public var name: String?
    public var volume: String
    /// `nil` while locked.
    public var messages: Int?
    /// Encrypted and its key not loaded on the server: nothing of it can be read.
    public var locked: Bool
    /// Encrypted: Face ID first, as for its chat, and never its name outside it.
    public var isPrivate: Bool

    public var id: TopicID { chat }

    public init(chat: TopicID, name: String? = nil, volume: String, messages: Int?, locked: Bool = false, isPrivate: Bool = false) {
        self.chat = chat
        self.name = name
        self.volume = volume
        self.messages = messages
        self.locked = locked
        self.isPrivate = isPrivate
    }

    enum CodingKeys: String, CodingKey { case chat, name, volume, messages, locked, isPrivate = "private" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let chat = c.decodeTopic(.chat) else {
            throw DecodingError.keyNotFound(CodingKeys.chat, .init(codingPath: c.codingPath, debugDescription: "chat"))
        }
        self.chat = chat
        name = (try? c.decodeIfPresent(String.self, forKey: .name))?.nilIfEmpty
        volume = (try? c.decodeIfPresent(String.self, forKey: .volume)) ?? ""
        messages = c.decodeInt64(.messages).map { Int($0) }
        locked = (try? c.decode(Bool.self, forKey: .locked)) ?? false
        isPrivate = (try? c.decode(Bool.self, forKey: .isPrivate)) ?? false
    }
}

/// One line of a memory: the summary of messages `first` to `last`.
public struct MemoryLine: Sendable, Hashable, Identifiable, Decodable {
    public var first: Int
    public var n: Int
    /// `nil` until Hermes has summarized it (it can still be opened).
    public var text: String?
    public var built: Bool

    public var id: String { "\(first)+\(n)" }
    public var last: Int { first + n - 1 }
    /// A one-message line opens on the message itself, the others on their two halves.
    public var isMessage: Bool { n == 1 }

    public init(first: Int, n: Int, text: String?, built: Bool? = nil) {
        self.first = first
        self.n = n
        self.text = text
        self.built = built ?? (text != nil)
    }

    enum CodingKeys: String, CodingKey { case first, n, text, built }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let first = c.decodeInt64(.first), let n = c.decodeInt64(.n), n >= 1, first >= 0 else {
            throw DecodingError.keyNotFound(CodingKeys.first, .init(codingPath: c.codingPath, debugDescription: "first, n"))
        }
        self.first = Int(first)
        self.n = Int(n)
        text = (try? c.decodeIfPresent(String.self, forKey: .text))?.nilIfEmpty
        built = (try? c.decode(Bool.self, forKey: .built)) ?? (text != nil)
    }
}

/// One message of the log, as unii stored it.
public struct MemoryMessage: Sendable, Equatable, Decodable {
    public enum Kind: String, Sendable, Equatable {
        case user, hermes, tool, echo, work, note
    }

    public var index: Int
    /// `nil` for a kind this app doesn't know yet (shown as sent).
    public var kind: Kind?
    public var rawKind: String
    public var date: Date?
    public var text: String
    /// The server cut a long text to fit one reply (it ends with "…").
    public var isCut: Bool

    public init(index: Int, kind: String, date: Date?, text: String, isCut: Bool = false) {
        self.index = index
        self.rawKind = kind
        self.kind = Kind(rawValue: kind)
        self.date = date
        self.text = text
        self.isCut = isCut
    }

    enum CodingKeys: String, CodingKey { case index = "i", kind, date, text, isCut = "cut" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let i = c.decodeInt64(.index) else {
            throw DecodingError.keyNotFound(CodingKeys.index, .init(codingPath: c.codingPath, debugDescription: "i"))
        }
        index = Int(i)
        rawKind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        kind = Kind(rawValue: rawKind)
        date = c.decodeFlexibleDate(.date)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        isCut = (try? c.decode(Bool.self, forKey: .isCut)) ?? false
    }
}

/// A page of a memory's view: its lines, and where the next page starts if there is one.
public struct MemoryPage: Sendable, Equatable {
    public var lines: [MemoryLine]
    /// The `after` of the next page; `nil` on the last one.
    public var next: Int?

    public init(lines: [MemoryLine], next: Int? = nil) {
        self.lines = lines
        self.next = next
    }
}

/// Why a memory couldn't be read, from the reply's error code.
public enum MemoryError: LocalizedError, Sendable, Equatable {
    case locked
    case notFound
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .locked: L("This memory is locked.")
        case .notFound: L("This memory no longer exists.")
        case .unavailable: L("Hermes' memory isn't available on the server.")
        case .failed(let message): message.isEmpty ? L("Hermes couldn't read its memory.") : message
        }
    }

    init(reply: ReplyPayload) {
        switch reply.errorCode {
        case "locked": self = .locked
        case "not_found": self = .notFound
        case "unavailable", "unknown_type": self = .unavailable
        default: self = .failed(reply.errorMessage ?? "")
        }
    }
}

/// Decoding a `memory.*` reply's `data`.
public enum MemoryReply {
    static func data(_ reply: ReplyPayload?) throws -> [String: JSONValue] {
        guard let reply else { throw MemoryError.failed("") }
        guard reply.ok else { throw MemoryError(reply: reply) }
        if case .object(let data)? = reply["data"] { return data }
        return [:]
    }

    public static func volumes(_ reply: ReplyPayload?) throws -> [MemoryVolume] {
        try data(reply).decodeArray(MemoryVolume.self, key: "volumes")
    }

    public static func page(_ reply: ReplyPayload?) throws -> MemoryPage {
        let data = try data(reply)
        var next: Int?
        if data["truncated"] == .bool(true), case .number(let n)? = data["next"] { next = Int(n) }
        return MemoryPage(lines: data.decodeArray(MemoryLine.self, key: "lines"), next: next)
    }

    public static func message(_ reply: ReplyPayload?) throws -> MemoryMessage {
        guard let message = try data(reply).decode(MemoryMessage.self, key: "message") else { throw MemoryError.failed("") }
        return message
    }
}

extension AppRequest {
    public static let memoryVolumes = AppRequest(type: "memory.volumes")

    /// The view Hermes sees for that chat's memory, from message `after` on.
    public static func memoryView(chat: TopicID, after: Int? = nil) -> AppRequest {
        var payload: [String: JSONValue] = ["chat": .number(Double(chat))]
        if let after { payload["after"] = .number(Double(after)) }
        return AppRequest(type: "memory.lines", payload: payload)
    }

    /// A line's two halves, or for a one-message line the message.
    public static func memoryLine(chat: TopicID, first: Int, n: Int) -> AppRequest {
        AppRequest(type: "memory.lines", payload: ["chat": .number(Double(chat)), "first": .number(Double(first)), "n": .number(Double(n))])
    }
}
