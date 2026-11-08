import Foundation

/// A forum topic of the DM with the bot. 0 is the main chat (messages outside any topic).
public typealias TopicID = Int32
public typealias MessageID = Int64
public typealias ChatID = Int64

public extension TopicID {
    static let main: TopicID = 0
}

/// Telegram's formatted text, kept close to TDLib's `formattedText` so both the real client and
/// the fixtures produce it. Offsets and lengths are in UTF-16 code units, as in TDLib.
public struct FormattedText: Hashable, Sendable, Codable {
    public var text: String
    public var entities: [TextEntity]

    public init(_ text: String, entities: [TextEntity] = []) {
        self.text = text
        self.entities = entities
    }
}

public struct TextEntity: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case bold, italic, underline, strikethrough, spoiler
        case code
        case pre(language: String?)
        case blockquote
        case url
        case textURL(String)
        case mention
        case botCommand
    }

    public var offset: Int
    public var length: Int
    public var kind: Kind

    public init(offset: Int, length: Int, kind: Kind) {
        self.offset = offset
        self.length = length
        self.kind = kind
    }
}

public struct InlineButton: Hashable, Sendable, Codable, Identifiable {
    public enum Action: Hashable, Sendable, Codable {
        case callback(Data)
        case url(URL)
        case other
    }

    public var id: String { "\(row).\(column)" }
    public var row: Int
    public var column: Int
    public var label: String
    public var action: Action

    public init(row: Int, column: Int, label: String, action: Action) {
        self.row = row
        self.column = column
        self.label = label
        self.action = action
    }
}

public struct FileAttachment: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case document, photo, video, audio, voice
    }

    public var kind: Kind
    public var fileID: Int32
    public var name: String
    public var mimeType: String?
    public var size: Int64
    /// Local path once downloaded (or the thumbnail for photos), if any.
    public var localPath: String?
    public var width: Int?
    public var height: Int?

    public init(kind: Kind, fileID: Int32, name: String, mimeType: String? = nil, size: Int64,
                localPath: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.kind = kind
        self.fileID = fileID
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.localPath = localPath
        self.width = width
        self.height = height
    }
}

public struct ChatMessage: Hashable, Sendable, Codable, Identifiable {
    public enum SendState: Hashable, Sendable, Codable {
        case sent, pending, failed(String)
    }

    public var id: MessageID
    public var topic: TopicID
    public var date: Date
    public var editDate: Date?
    public var isOutgoing: Bool
    public var text: FormattedText
    public var attachment: FileAttachment?
    public var buttons: [InlineButton]
    public var sendState: SendState
    public var replyTo: MessageID?

    public init(id: MessageID, topic: TopicID, date: Date, editDate: Date? = nil, isOutgoing: Bool,
                text: FormattedText, attachment: FileAttachment? = nil, buttons: [InlineButton] = [],
                sendState: SendState = .sent, replyTo: MessageID? = nil) {
        self.id = id
        self.topic = topic
        self.date = date
        self.editDate = editDate
        self.isOutgoing = isOutgoing
        self.text = text
        self.attachment = attachment
        self.buttons = buttons
        self.sendState = sendState
        self.replyTo = replyTo
    }

    /// Text without the `[fichier: …]` markers, which render as cards instead.
    public var displayText: String { FileLink.strip(from: text.text) }
    public var fileLinks: [FileLink] { FileLink.parse(text.text) }
}

/// What a reply shows above itself (design-rules 16.1): who wrote the original and its first
/// line — or that it is still being fetched, or gone.
public struct ReplyPreview: Hashable, Sendable {
    public enum Author: Hashable, Sendable { case you, hermes }
    public enum Content: Hashable, Sendable {
        case message(author: Author, excerpt: String)
        case loading
        case deleted
    }

    public var originalID: MessageID
    public var content: Content

    public init(originalID: MessageID, content: Content) {
        self.originalID = originalID
        self.content = content
    }

    public init(original m: ChatMessage) {
        self.init(originalID: m.id, content: .message(author: m.isOutgoing ? .you : .hermes, excerpt: Self.excerpt(of: m)))
    }

    /// The original's first line of text (code fences and file markers left out), or its file's
    /// name when it has no text.
    public static func excerpt(of m: ChatMessage) -> String {
        let line = m.displayText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") }
        return line ?? m.attachment?.name ?? m.fileLinks.first?.url.lastPathComponent ?? ""
    }
}

/// A message the bot is still writing: Telegram's native draft in the main chat
/// (`updatePendingMessage`), shown until the real message arrives.
public struct StreamingDraft: Hashable, Sendable {
    public var draftID: Int64
    public var topic: TopicID
    public var text: FormattedText
    public var canStop: Bool
    public var updatedAt: Date

    public init(draftID: Int64, topic: TopicID, text: FormattedText, canStop: Bool, updatedAt: Date = .now) {
        self.draftID = draftID
        self.topic = topic
        self.text = text
        self.canStop = canStop
        self.updatedAt = updatedAt
    }
}

public struct ChatThread: Hashable, Sendable, Identifiable {
    public var id: TopicID
    public var name: String
    public var iconColor: Int32
    public var iconEmoji: String?
    public var lastMessage: ChatMessage?
    public var unreadCount: Int
    public var isPinned: Bool
    public var order: Int64

    public init(id: TopicID, name: String, iconColor: Int32 = 0x6FB9F0, iconEmoji: String? = nil,
                lastMessage: ChatMessage? = nil, unreadCount: Int = 0, isPinned: Bool = false, order: Int64 = 0) {
        self.id = id
        self.name = name
        self.iconColor = iconColor
        self.iconEmoji = iconEmoji
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.order = order
    }

    public var isMain: Bool { id == .main }
}
