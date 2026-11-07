import Foundation
import HermesCore
@preconcurrency import TDLibKit
import UIKit

/// `TelegramClient` over TDLib (TDLibKit). TDLib keeps its database in Application Support, so a
/// cold start shows the last messages before the network is up.
@MainActor
final class TDLibTelegramClient: TelegramClient {
    let events: AsyncStream<TelegramEvent>
    private let continuation: AsyncStream<TelegramEvent>.Continuation
    private(set) var uploadLimit: Int64 = 2 * 1024 * 1024 * 1024

    private let config: AppConfig
    private let manager = TDLibClientManager()
    private var client: TDLibClient!
    private var botChatID: Int64?
    private var phone = ""

    init(config: AppConfig) {
        self.config = config
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func start() {
        guard client == nil else { return }
        client = manager.createClient { @Sendable data, client in
            // TDLibKit calls this on its own queue; decode there, hop to the main actor with values.
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            Task { @MainActor [weak self] in self?.handle(update) }
        }
        _ = try? client.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
    }

    private func emit(_ e: TelegramEvent) { continuation.yield(e) }

    // MARK: Updates

    private func handle(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let u):
            handleAuth(u.authorizationState)
        case .updateConnectionState(let u):
            switch u.state {
            case .connectionStateWaitingForNetwork: emit(.connection(.waitingForNetwork))
            case .connectionStateConnecting, .connectionStateConnectingToProxy: emit(.connection(.connecting))
            case .connectionStateUpdating: emit(.connection(.updating))
            case .connectionStateReady: emit(.connection(.ready))
            }
        case .updateNewMessage(let u):
            guard u.message.chatId == botChatID else { return }
            emit(.newMessage(u.message.chatId, Self.convert(u.message)))
        case .updateMessageContent(let u):
            guard u.chatId == botChatID else { return }
            // The content alone lacks the topic and date: refetch the message, cheap from TDLib's cache.
            Task {
                guard let m = try? await client.getMessage(chatId: u.chatId, messageId: u.messageId) else { return }
                emit(.messageChanged(u.chatId, Self.convert(m)))
            }
        case .updateMessageEdited(let u):
            guard u.chatId == botChatID else { return }
            Task {
                guard let m = try? await client.getMessage(chatId: u.chatId, messageId: u.messageId) else { return }
                emit(.messageChanged(u.chatId, Self.convert(m)))
            }
        case .updateDeleteMessages(let u):
            guard u.chatId == botChatID, u.isPermanent else { return }
            emit(.messagesDeleted(u.chatId, u.messageIds))
        case .updateMessageSendSucceeded(let u):
            emit(.messageSent(u.message.chatId, oldID: u.oldMessageId, Self.convert(u.message)))
        case .updateMessageSendFailed(let u):
            emit(.messageFailed(u.message.chatId, oldID: u.oldMessageId, error: u.error.message))
        case .updatePendingMessage(let u):
            guard u.chatId == botChatID else { return }
            let text: HermesCore.FormattedText
            if case .messageText(let t) = u.content { text = Self.convert(t.text) } else { text = HermesCore.FormattedText("") }
            emit(.draft(u.chatId, StreamingDraft(draftID: u.draftId.rawValue, topic: TopicID(u.forumTopicId), text: text, canStop: u.canStop)))
        case .updateStopMessageDraft(let u):
            emit(.draftStopped(u.chatId, topic: TopicID(u.forumTopicId), draftID: u.draftId.rawValue))
        case .updateForumTopicInfo(let u):
            guard u.info.chatId == botChatID else { return }
            emit(.topic(u.info.chatId, Self.convert(u.info)))
        case .updateChatAction(let u):
            guard u.chatId == botChatID else { return }
            let topic = Self.topic(u.topicId)
            if case .chatActionCancel = u.action { emit(.typing(u.chatId, topic: topic, active: false)) }
            else { emit(.typing(u.chatId, topic: topic, active: true)) }
        case .updateFile(let u):
            emit(.fileUpdated(fileID: Int32(u.file.id), localPath: u.file.local.isDownloadingCompleted ? u.file.local.path : nil,
                              downloaded: u.file.local.downloadedSize, total: u.file.expectedSize))
        case .updateOption(let u):
            if u.name == "is_premium", case .optionValueBoolean(let b) = u.value {
                uploadLimit = (b.value ? 4 : 2) * 1024 * 1024 * 1024
            }
        default:
            break
        }
    }

    private func handleAuth(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            Task { await setParameters() }
        case .authorizationStateWaitPhoneNumber:
            emit(.auth(.waitPhoneNumber))
        case .authorizationStateWaitCode(let s):
            emit(.auth(.waitCode(phone: s.codeInfo.phoneNumber, via: Self.describe(s.codeInfo.type),
                                 length: Self.length(s.codeInfo.type), nextVia: s.codeInfo.nextType.map(Self.describe))))
        case .authorizationStateWaitPassword(let s):
            emit(.auth(.waitPassword(hint: s.passwordHint)))
        case .authorizationStateWaitRegistration:
            emit(.auth(.waitRegistration))
        case .authorizationStateReady:
            emit(.auth(.ready))
        case .authorizationStateLoggingOut:
            emit(.auth(.loggingOut))
        case .authorizationStateClosed:
            emit(.auth(.closed))
            // A logout closes the client: start a fresh one, which asks for the phone again.
            client = nil
            start()
        default:
            break
        }
    }

    private func setParameters() async {
        guard let apiID = config.apiID, let apiHash = config.apiHash else {
            emit(.auth(.missingConfiguration("HERMES_TG_API_ID and HERMES_TG_API_HASH aren't set in this build.")))
            return
        }
        let dir = URL.applicationSupportDirectory.appending(path: "tdlib", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = UIDevice.current
        _ = try? await client.setTdlibParameters(
            apiHash: apiHash, apiId: Int(apiID),
            applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            databaseDirectory: dir.path, databaseEncryptionKey: Data(),
            deviceModel: device.model, filesDirectory: dir.appending(path: "files").path,
            systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
            systemVersion: device.systemVersion,
            useChatInfoDatabase: true, useFileDatabase: true, useMessageDatabase: true,
            useSecretChats: false, useTestDc: false)
    }

    // MARK: Login

    func setPhoneNumber(_ phone: String) async throws {
        self.phone = phone
        try await run {
            _ = try await self.client.setAuthenticationPhoneNumber(
                phoneNumber: phone,
                settings: PhoneNumberAuthenticationSettings(
                    allowFlashCall: false, allowMissedCall: false, allowSmsRetrieverApi: false,
                    authenticationTokens: [], firebaseAuthenticationSettings: nil,
                    hasUnknownPhoneNumber: false, isCurrentPhoneNumber: true))
        }
    }

    func checkCode(_ code: String) async throws {
        try await run { _ = try await self.client.checkAuthenticationCode(code: code) }
    }

    func resendCode() async throws {
        try await run { _ = try await self.client.resendAuthenticationCode(reason: nil) }
    }

    func checkPassword(_ password: String) async throws {
        try await run { _ = try await self.client.checkAuthenticationPassword(password: password) }
    }

    func logOut() async throws {
        try await run { _ = try await self.client.logOut() }
    }

    // MARK: Chat

    func findBot(username: String) async throws -> BotChat {
        let chat: Chat
        do {
            chat = try await client.searchPublicChat(username: username)
        } catch {
            throw TelegramError.botNotFound(username)
        }
        guard case .chatTypePrivate(let p) = chat.type else { throw TelegramError.botNotFound(username) }
        botChatID = chat.id
        _ = try? await client.openChat(chatId: chat.id)
        return BotChat(chatID: chat.id, userID: p.userId, title: chat.title, username: username)
    }

    func topics(in chat: ChatID) async throws -> [ChatThread] {
        var out: [ChatThread] = []
        var offsetDate = 0, offsetMessage: Int64 = 0, offsetTopic = 0
        // A bot DM rarely has more than a few dozen topics; page anyway.
        for _ in 0..<10 {
            let page = try await wrap {
                try await self.client.getForumTopics(chatId: chat, limit: 100, offsetDate: offsetDate,
                                                     offsetForumTopicId: offsetTopic, offsetMessageId: offsetMessage, query: "")
            }
            out += page.topics.map { t in
                var thread = Self.convert(t.info)
                thread.lastMessage = t.lastMessage.map(Self.convert)
                thread.unreadCount = t.unreadCount
                thread.isPinned = t.isPinned
                thread.order = t.order.rawValue
                return thread
            }
            if page.topics.count < 100 || page.nextOffsetForumTopicId == 0 { break }
            offsetDate = page.nextOffsetDate
            offsetMessage = page.nextOffsetMessageId
            offsetTopic = page.nextOffsetForumTopicId
        }
        return out
    }

    func history(chat: ChatID, topic: TopicID, from fromMessageID: MessageID, limit: Int) async throws -> [ChatMessage] {
        // TDLib may return fewer messages than asked while it fetches from the server: ask until
        // the page is full or nothing more comes.
        var collected: [Message] = []
        var from = fromMessageID
        for _ in 0..<4 where collected.count < limit {
            let page: Messages = try await wrap {
                if topic == .main {
                    try await self.client.getChatHistory(chatId: chat, fromMessageId: from, limit: limit - collected.count, offset: 0, onlyLocal: false)
                } else {
                    try await self.client.getForumTopicHistory(chatId: chat, forumTopicId: Int(topic), fromMessageId: from,
                                                               limit: limit - collected.count, offset: 0)
                }
            }
            let msgs = (page.messages ?? []).filter { topic != .main || Self.topic($0.topicId) == .main }
            if page.messages?.isEmpty ?? true { break }
            collected += msgs
            from = page.messages!.last!.id
        }
        return collected.map(Self.convert)
    }

    func send(text: String, chat: ChatID, topic: TopicID, replyTo: MessageID?) async throws -> ChatMessage {
        let content = InputMessageContent.inputMessageText(InputMessageText(
            clearDraft: true, linkPreviewOptions: nil, text: TDLibKit.FormattedText(entities: [], text: text)))
        // TDLibKit's models aren't Sendable; they never leave this call.
        nonisolated(unsafe) let reply: InputMessageReplyTo? = replyTo.map {
            .inputMessageReplyToMessage(InputMessageReplyToMessage(checklistTaskId: 0, messageId: $0, pollOptionId: "", quote: nil))
        }
        let m = try await wrap {
            try await self.client.sendMessage(chatId: chat, inputMessageContent: content, options: nil, replyMarkup: nil,
                                              replyTo: reply, topicId: Self.messageTopic(topic))
        }
        return Self.convert(m)
    }

    func sendFile(at url: URL, caption: String, chat: ChatID, topic: TopicID) async throws -> ChatMessage {
        let content = InputMessageContent.inputMessageDocument(InputMessageDocument(
            caption: TDLibKit.FormattedText(entities: [], text: caption),
            document: InputDocument(disableContentTypeDetection: false, document: .inputFileLocal(InputFileLocal(path: url.path)), thumbnail: nil)))
        let m = try await wrap {
            try await self.client.sendMessage(chatId: chat, inputMessageContent: content, options: nil, replyMarkup: nil,
                                              replyTo: nil, topicId: Self.messageTopic(topic))
        }
        return Self.convert(m)
    }

    func delete(messages: [MessageID], chat: ChatID) async throws {
        try await run { _ = try await self.client.deleteMessages(chatId: chat, messageIds: messages, revoke: true) }
    }

    func pressButton(chat: ChatID, message: MessageID, data: Data) async throws -> String? {
        let answer = try await wrap {
            try await self.client.getCallbackQueryAnswer(chatId: chat, messageId: message,
                                                         payload: .callbackQueryPayloadData(CallbackQueryPayloadData(data: data)))
        }
        return answer.text.isEmpty ? nil : answer.text
    }

    func stopDraft(chat: ChatID, topic: TopicID, draftID: Int64) async throws {
        try await run {
            _ = try await self.client.stopPendingMessage(chatId: chat, draftId: TdInt64(draftID), topicId: Self.messageTopic(topic))
        }
    }

    func download(fileID: Int32) async throws -> URL {
        let file = try await wrap {
            try await self.client.downloadFile(fileId: Int(fileID), limit: 0, offset: 0, priority: 16, synchronous: true)
        }
        guard file.local.isDownloadingCompleted else { throw TelegramError.server(code: 500, message: "Download failed.") }
        return URL(filePath: file.local.path)
    }

    func markRead(chat: ChatID, topic: TopicID, messages: [MessageID]) async {
        _ = try? await client.viewMessages(chatId: chat, forceRead: true, messageIds: messages,
                                           source: topic == .main ? .messageSourceChatHistory : .messageSourceForumTopicHistory)
    }

    func setTyping(chat: ChatID, topic: TopicID) async {
        _ = try? await client.sendChatAction(action: .chatActionTyping, businessConnectionId: "", chatId: chat, topicId: Self.messageTopic(topic))
    }

    /// Registers with Telegram too, in case Telegram ever pushes to this bundle id; Hermes'
    /// own APNs push (paid team) is what actually reaches the app (DECISIONS.md).
    func registerForPush(token: Data) async throws {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        _ = try? await client.registerDevice(deviceToken: .deviceTokenApplePush(DeviceTokenApplePush(deviceToken: hex, isAppSandbox: true)),
                                             otherUserIds: [])
    }

    // MARK: Helpers

    private func run(_ body: @escaping () async throws -> Void) async throws {
        do { try await body() } catch { throw Self.map(error) }
    }

    private func wrap<T>(_ body: @escaping () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw Self.map(error) }
    }

    nonisolated static func map(_ error: Swift.Error) -> Swift.Error {
        if let e = error as? TDLibKit.Error { return TelegramError.server(code: e.code, message: e.message) }
        return error
    }

    nonisolated static func messageTopic(_ topic: TopicID) -> MessageTopic? {
        topic == .main ? nil : .messageTopicForum(MessageTopicForum(forumTopicId: Int(topic)))
    }

    nonisolated static func topic(_ t: MessageTopic?) -> TopicID {
        if case .messageTopicForum(let f)? = t { return TopicID(f.forumTopicId) }
        return .main
    }

    nonisolated static func describe(_ type: AuthenticationCodeType) -> String {
        switch type {
        case .authenticationCodeTypeTelegramMessage: "Telegram"
        case .authenticationCodeTypeSms, .authenticationCodeTypeSmsWord, .authenticationCodeTypeSmsPhrase: "SMS"
        case .authenticationCodeTypeCall, .authenticationCodeTypeFlashCall, .authenticationCodeTypeMissedCall: "a phone call"
        case .authenticationCodeTypeFragment: "Fragment"
        default: "Telegram"
        }
    }

    nonisolated static func length(_ type: AuthenticationCodeType) -> Int {
        switch type {
        case .authenticationCodeTypeTelegramMessage(let t): t.length
        case .authenticationCodeTypeSms(let t): t.length
        case .authenticationCodeTypeCall(let t): t.length
        default: 5
        }
    }

    nonisolated static func convert(_ info: ForumTopicInfo) -> ChatThread {
        ChatThread(id: TopicID(info.forumTopicId), name: info.name, iconColor: Int32(truncatingIfNeeded: info.icon.color))
    }

    nonisolated static func convert(_ t: TDLibKit.FormattedText) -> HermesCore.FormattedText {
        HermesCore.FormattedText(t.text, entities: t.entities.compactMap { e in
            let kind: HermesCore.TextEntity.Kind
            switch e.type {
            case .textEntityTypeBold: kind = .bold
            case .textEntityTypeItalic: kind = .italic
            case .textEntityTypeUnderline: kind = .underline
            case .textEntityTypeStrikethrough: kind = .strikethrough
            case .textEntityTypeSpoiler: kind = .spoiler
            case .textEntityTypeCode: kind = .code
            case .textEntityTypePre: kind = .pre(language: nil)
            case .textEntityTypePreCode(let p): kind = .pre(language: p.language)
            case .textEntityTypeBlockQuote, .textEntityTypeExpandableBlockQuote: kind = .blockquote
            case .textEntityTypeUrl: kind = .url
            case .textEntityTypeTextUrl(let u): kind = .textURL(u.url)
            case .textEntityTypeMention: kind = .mention
            case .textEntityTypeBotCommand: kind = .botCommand
            default: return nil
            }
            return HermesCore.TextEntity(offset: e.offset, length: e.length, kind: kind)
        })
    }

    nonisolated static func convert(_ m: Message) -> ChatMessage {
        var text = HermesCore.FormattedText("")
        var attachment: FileAttachment?
        switch m.content {
        case .messageText(let t):
            text = convert(t.text)
        case .messageDocument(let d):
            text = convert(d.caption)
            attachment = file(.document, d.document.document, name: d.document.fileName, mime: d.document.mimeType)
        case .messagePhoto(let p):
            text = convert(p.caption)
            if let best = p.photo.sizes.last {
                attachment = file(.photo, best.photo, name: "Photo.jpg", mime: "image/jpeg", width: best.width, height: best.height)
            }
        case .messageVideo(let v):
            text = convert(v.caption)
            attachment = file(.video, v.video.video, name: v.video.fileName.isEmpty ? "Video.mp4" : v.video.fileName, mime: v.video.mimeType)
        case .messageAudio(let a):
            text = convert(a.caption)
            attachment = file(.audio, a.audio.audio, name: a.audio.fileName, mime: a.audio.mimeType)
        case .messageVoiceNote(let v):
            text = convert(v.caption)
            attachment = file(.voice, v.voiceNote.voice, name: "Voice message.ogg", mime: v.voiceNote.mimeType)
        default:
            text = HermesCore.FormattedText("Unsupported message")
        }
        var buttons: [HermesCore.InlineButton] = []
        if case .replyMarkupInlineKeyboard(let kb)? = m.replyMarkup {
            for (r, row) in kb.rows.enumerated() {
                for (c, b) in row.enumerated() {
                    let action: HermesCore.InlineButton.Action
                    switch b.type {
                    case .inlineKeyboardButtonTypeCallback(let cb): action = .callback(cb.data)
                    case .inlineKeyboardButtonTypeUrl(let u): action = URL(string: u.url).map(HermesCore.InlineButton.Action.url) ?? .other
                    default: action = .other
                    }
                    buttons.append(HermesCore.InlineButton(row: r, column: c, label: b.text, action: action))
                }
            }
        }
        var state: ChatMessage.SendState = .sent
        switch m.sendingState {
        case .messageSendingStatePending?: state = .pending
        case .messageSendingStateFailed(let f)?: state = .failed(f.error.message)
        default: break
        }
        var replyTo: MessageID?
        if case .messageReplyToMessage(let r)? = m.replyTo { replyTo = r.messageId }
        return ChatMessage(id: m.id, topic: topic(m.topicId), date: Date(timeIntervalSince1970: TimeInterval(m.date)),
                           editDate: m.editDate > 0 ? Date(timeIntervalSince1970: TimeInterval(m.editDate)) : nil,
                           isOutgoing: m.isOutgoing, text: text, attachment: attachment, buttons: buttons,
                           sendState: state, replyTo: replyTo)
    }

    nonisolated static func file(_ kind: FileAttachment.Kind, _ f: File, name: String, mime: String?, width: Int? = nil, height: Int? = nil) -> FileAttachment {
        FileAttachment(kind: kind, fileID: Int32(f.id), name: name, mimeType: mime, size: f.size > 0 ? f.size : f.expectedSize,
                       localPath: f.local.isDownloadingCompleted ? f.local.path : nil, width: width, height: height)
    }
}
