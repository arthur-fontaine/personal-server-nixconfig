import Foundation

public enum AuthState: Equatable, Sendable {
    case starting
    case waitPhoneNumber
    /// `via` says where the code went ("Telegram", "SMS"…); `length` its digits.
    case waitCode(phone: String, via: String, length: Int, nextVia: String?)
    case waitPassword(hint: String)
    case waitRegistration
    case ready
    case loggingOut
    case closed
    case missingConfiguration(String)
}

public enum ConnectionState: Equatable, Sendable {
    case waitingForNetwork, connecting, updating, ready
}

/// The bot's DM, once found.
public struct BotChat: Equatable, Sendable {
    public var chatID: ChatID
    public var userID: Int64
    public var title: String
    public var username: String

    public init(chatID: ChatID, userID: Int64, title: String, username: String) {
        self.chatID = chatID
        self.userID = userID
        self.title = title
        self.username = username
    }
}

public enum TelegramEvent: Sendable {
    case auth(AuthState)
    case connection(ConnectionState)
    case newMessage(ChatID, ChatMessage)
    /// Content changed: the bot editing a streamed message, or the App slots.
    case messageChanged(ChatID, ChatMessage)
    case messagesDeleted(ChatID, [MessageID])
    /// A locally sent message got its server id.
    case messageSent(ChatID, oldID: MessageID, ChatMessage)
    case messageFailed(ChatID, oldID: MessageID, error: String)
    case draft(ChatID, StreamingDraft)
    case draftStopped(ChatID, topic: TopicID, draftID: Int64)
    case topic(ChatID, ChatThread)
    case fileUpdated(fileID: Int32, localPath: String?, downloaded: Int64, total: Int64)
    case typing(ChatID, topic: TopicID, active: Bool)
}

public enum TelegramError: LocalizedError, Sendable {
    case botNotFound(String)
    case notReady
    case server(code: Int, message: String)
    case fileTooBig(limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .botNotFound(let u): L("Couldn't find @\(u) on Telegram.")
        case .notReady: L("Telegram isn't connected yet.")
        case .server(_, let message): Self.humanize(message)
        case .fileTooBig: L("This file is too big for Telegram.")
        }
    }

    static func humanize(_ message: String) -> String {
        switch message {
        case "PHONE_CODE_INVALID": L("That code isn't right. Check it and try again.")
        case "PHONE_CODE_EXPIRED": L("That code expired. Ask for a new one.")
        case "PHONE_NUMBER_INVALID": L("That phone number doesn't look right.")
        case "PASSWORD_HASH_INVALID": L("Wrong password.")
        case "PHONE_NUMBER_BANNED": L("This number is banned from Telegram.")
        default:
            if message.hasPrefix("Too Many Requests") || message.hasPrefix("FLOOD_WAIT") {
                L("Too many attempts. Wait a little and try again.")
            } else { message }
        }
    }
}

/// What the app needs from Telegram, narrowed to one DM. `TDLibTelegramClient` (app target)
/// implements it over TDLib; `FakeTelegramClient` over fixtures, for the demo, previews and tests.
@MainActor
public protocol TelegramClient: AnyObject {
    /// Single consumer: the store.
    var events: AsyncStream<TelegramEvent> { get }
    /// Telegram's upload cap for this account (2 GB, 4 GB with Premium).
    var uploadLimit: Int64 { get }

    func start()
    func setPhoneNumber(_ phone: String) async throws
    func checkCode(_ code: String) async throws
    func resendCode() async throws
    func checkPassword(_ password: String) async throws
    func logOut() async throws

    func findBot(username: String) async throws -> BotChat
    func topics(in chat: ChatID) async throws -> [ChatThread]
    /// Newest first, from `fromMessageID` (0: the newest) backwards.
    func history(chat: ChatID, topic: TopicID, from fromMessageID: MessageID, limit: Int) async throws -> [ChatMessage]
    func send(text: String, chat: ChatID, topic: TopicID, replyTo: MessageID?) async throws -> ChatMessage
    func sendFile(at url: URL, caption: String, chat: ChatID, topic: TopicID) async throws -> ChatMessage
    func delete(messages: [MessageID], chat: ChatID) async throws
    /// Presses an inline button, as a tap in Telegram does. Returns the bot's toast, if any.
    func pressButton(chat: ChatID, message: MessageID, data: Data) async throws -> String?
    func stopDraft(chat: ChatID, topic: TopicID, draftID: Int64) async throws
    func download(fileID: Int32) async throws -> URL
    func markRead(chat: ChatID, topic: TopicID, messages: [MessageID]) async
    func setTyping(chat: ChatID, topic: TopicID) async
    /// Paid team only: Telegram's own push is useless to a third-party bundle id; see DECISIONS.
    func registerForPush(token: Data) async throws
}
