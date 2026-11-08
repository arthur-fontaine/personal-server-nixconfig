import Foundation
import Observation

/// Hooks the app plugs in for what lives outside the core: notifications, Live Activities,
/// widgets. All optional, so tests and previews run without them.
@MainActor
public struct StoreHooks {
    public var notify: (NotifyPayload) -> Void = { _ in }
    public var stateChanged: (AppState) -> Void = { _ in }
    public var statsChanged: (StatsState) -> Void = { _ in }
    public var spriteAvailable: (PetState, URL) -> Void = { _, _ in }
    public init() {}
}

@MainActor
@Observable
public final class HermesStore {
    // MARK: Telegram
    public private(set) var auth: AuthState = .starting
    public private(set) var connection: ConnectionState = .connecting
    public private(set) var bot: BotChat?
    public private(set) var botError: String?

    // MARK: Chats
    /// Sub-chat topics, without the hidden App topic.
    public private(set) var threads: [ChatThread] = []
    public private(set) var mainThread = ChatThread(id: .main, name: "Hermes")
    public private(set) var messages: [TopicID: [ChatMessage]] = [:]
    public private(set) var drafts: [TopicID: StreamingDraft] = [:]
    public private(set) var typing: Set<TopicID> = []
    public private(set) var reachedStart: Set<TopicID> = []
    public private(set) var appTopicID: TopicID?

    // MARK: App topic
    public private(set) var state = AppState()
    public private(set) var stats: StatsState?
    public private(set) var delivery = DeliveryState()
    public private(set) var controls = ControlsState()
    public private(set) var spriteURL: URL?
    private var slotIDs: [String: MessageID] = [:]
    private var pendingReplies: [MessageID: CheckedContinuation<ReplyPayload, Error>] = [:]
    private var earlyReplies: [MessageID: ReplyPayload] = [:]
    private var seenQuestions: Set<String> = []
    /// A one-shot row the pet plays over its mood, then the view clears it: `.jumping` for a
    /// caress or an answered question (the nod), `.waving` toward a question that just arrived.
    public var petReaction: PetAnimation?
    /// When the owner last caressed the pet: the trigger for its haptic and heart.
    public private(set) var caressedAt: Date?

    // MARK: Uploads
    public private(set) var uploads: [UUID: UploadProgress] = [:]

    public let client: any TelegramClient
    public let config: AppConfig
    public var hooks = StoreHooks()
    public let uploader: any BigFileUploader
    private var eventTask: Task<Void, Never>?
    private var botTask: Task<Void, Never>?

    public init(client: any TelegramClient, config: AppConfig, uploader: (any BigFileUploader)? = nil) {
        self.client = client
        self.config = config
        self.uploader = uploader ?? BigFileUploaders.preferred(config: config)
    }

    public func start() {
        guard eventTask == nil else { return }
        let stream = client.events
        eventTask = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
        client.start()
    }

    // MARK: - Derived

    public var pet: PetState? { state.pet }
    public var agent: AgentState { state.agent ?? AgentState(status: .idle) }
    public var petMood: PetMood {
        PetMood(agent: state.agent?.status, reported: state.pet?.mood, until: state.pet?.moodUntil)
    }
    /// The row to play now: a reaction, else the mood's loop (thinking reads, as Hermes' own pet does).
    public var petAnimation: PetAnimation {
        if let petReaction { return petReaction }
        if state.agent?.status == .thinking { return .review }
        return petMood.animation
    }
    public var questions: [PendingQuestion] { state.questions }

    public func messages(in topic: TopicID) -> [ChatMessage] { messages[topic] ?? [] }

    public func subchat(_ topic: TopicID) -> SubchatInfo? { state.subchats.first { $0.topicID == topic } }
    public func isPrivate(_ topic: TopicID) -> Bool { subchat(topic)?.encrypted ?? false }

    public func thread(_ topic: TopicID) -> ChatThread? {
        topic == .main ? mainThread : threads.first { $0.id == topic }
    }

    public func questions(in topic: TopicID) -> [PendingQuestion] { state.questions.filter { $0.chat == topic } }

    public func question(forMessage id: MessageID) -> PendingQuestion? { state.questions.first { $0.messageID == id } }

    public var isReady: Bool { auth == .ready && bot != nil }

    // MARK: - Events

    func handle(_ event: TelegramEvent) {
        switch event {
        case .auth(let a):
            auth = a
            if a == .ready { connectBot() }
        case .connection(let c):
            connection = c
        case .newMessage(let chat, let m):
            guard chat == bot?.chatID else { return }
            if m.topic == appTopicID { handleAppMessage(m); return }
            insert(m)
            // The real message replaces the draft that streamed it.
            if !m.isOutgoing { drafts[m.topic] = nil; typing.remove(m.topic) }
            bumpThread(m)
        case .messageChanged(let chat, let m):
            guard chat == bot?.chatID else { return }
            if m.topic == appTopicID { handleAppMessage(m); return }
            replace(m)
        case .messagesDeleted(let chat, let ids):
            guard chat == bot?.chatID else { return }
            let set = Set(ids)
            for key in messages.keys { messages[key]?.removeAll { set.contains($0.id) } }
        case .messageSent(let chat, let oldID, let m):
            guard chat == bot?.chatID else { return }
            if m.topic == appTopicID { resolveSentRequest(oldID: oldID, newID: m.id); return }
            if let i = messages[m.topic]?.firstIndex(where: { $0.id == oldID }) { messages[m.topic]?[i] = m }
            else { insert(m) }
        case .messageFailed(let chat, let oldID, let error):
            guard chat == bot?.chatID else { return }
            for key in messages.keys {
                if let i = messages[key]?.firstIndex(where: { $0.id == oldID }) { messages[key]?[i].sendState = .failed(error) }
            }
        case .draft(let chat, let d):
            guard chat == bot?.chatID, d.topic != appTopicID else { return }
            drafts[d.topic] = d
        case .draftStopped(let chat, let topic, let id):
            guard chat == bot?.chatID, drafts[topic]?.draftID == id else { return }
            drafts[topic] = nil
        case .topic(let chat, let t):
            guard chat == bot?.chatID else { return }
            upsertThread(t)
        case .fileUpdated(let fileID, let path, _, _):
            guard let path else { return }
            for key in messages.keys {
                for (i, m) in (messages[key] ?? []).enumerated() where m.attachment?.fileID == fileID {
                    messages[key]?[i].attachment?.localPath = path
                }
            }
        case .typing(let chat, let topic, let active):
            guard chat == bot?.chatID else { return }
            if active { typing.insert(topic) } else { typing.remove(topic) }
        }
    }

    private func connectBot() {
        guard bot == nil, botTask == nil else { return }
        botTask = Task {
            defer { botTask = nil }
            do {
                let found = try await client.findBot(username: config.botUsername)
                bot = found
                botError = nil
                mainThread.name = found.title
                try await loadTopics()
                await loadHistory(.main)
                if let appTopicID { await loadAppTopic(appTopicID) }
                await sayHello()
            } catch {
                botError = error.localizedDescription
            }
        }
    }

    public func retryConnectBot() { connectBot() }

    private func loadTopics() async throws {
        guard let bot else { return }
        let all = try await client.topics(in: bot.chatID)
        // Several "App" topics can exist after a reset: the newest one is live (protocol §1).
        appTopicID = all.filter { $0.name == AppProtocol.topicName }.map(\.id).max()
        threads = all.filter { $0.name != AppProtocol.topicName && $0.id != .main }.sorted(by: Self.threadOrder)
    }

    private static func threadOrder(_ a: ChatThread, _ b: ChatThread) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        let da = a.lastMessage?.date ?? .distantPast, db = b.lastMessage?.date ?? .distantPast
        return da != db ? da > db : a.id > b.id
    }

    private func upsertThread(_ t: ChatThread) {
        if t.name == AppProtocol.topicName {
            if t.id > (appTopicID ?? 0) {
                appTopicID = t.id
                threads.removeAll { $0.id == t.id }
                Task { await loadAppTopic(t.id) }
            }
            return
        }
        if let i = threads.firstIndex(where: { $0.id == t.id }) {
            var merged = t
            if merged.lastMessage == nil { merged.lastMessage = threads[i].lastMessage }
            threads[i] = merged
        } else {
            threads.append(t)
        }
        threads.sort(by: Self.threadOrder)
    }

    private func bumpThread(_ m: ChatMessage) {
        if m.topic == .main {
            mainThread.lastMessage = m
            return
        }
        guard let i = threads.firstIndex(where: { $0.id == m.topic }) else { return }
        threads[i].lastMessage = m
        if !m.isOutgoing { threads[i].unreadCount += 1 }
        threads.sort(by: Self.threadOrder)
    }

    // MARK: - Messages

    private func insert(_ m: ChatMessage) {
        var list = messages[m.topic] ?? []
        if let i = list.firstIndex(where: { $0.id == m.id }) { list[i] = m }
        else if let last = list.last, last.id < m.id || m.sendState == .pending { list.append(m) }
        else {
            let i = list.firstIndex { $0.id > m.id } ?? list.endIndex
            list.insert(m, at: i)
        }
        messages[m.topic] = list
    }

    private func replace(_ m: ChatMessage) {
        guard let i = messages[m.topic]?.firstIndex(where: { $0.id == m.id }) else { return }
        messages[m.topic]?[i] = m
        if m.topic == .main, mainThread.lastMessage?.id == m.id { mainThread.lastMessage = m }
    }

    public func loadHistory(_ topic: TopicID) async {
        guard let bot else { return }
        do {
            let page = try await client.history(chat: bot.chatID, topic: topic, from: 0, limit: 50)
            let existing = messages[topic] ?? []
            let ids = Set(page.map(\.id))
            messages[topic] = (page.reversed() + existing.filter { !ids.contains($0.id) }).sorted { $0.id < $1.id }
            if page.count < 50 { reachedStart.insert(topic) }
            if topic == .main, let last = messages[topic]?.last { mainThread.lastMessage = last }
        } catch {}
    }

    public func loadOlder(_ topic: TopicID) async {
        guard let bot, !reachedStart.contains(topic), let oldest = messages[topic]?.first else { return }
        do {
            let page = try await client.history(chat: bot.chatID, topic: topic, from: oldest.id, limit: 50)
            let fresh = page.filter { $0.id < oldest.id }
            if fresh.isEmpty { reachedStart.insert(topic); return }
            messages[topic] = fresh.reversed() + (messages[topic] ?? [])
        } catch {}
    }

    public func markRead(_ topic: TopicID) {
        guard let bot, let last = messages[topic]?.last else { return }
        if let i = threads.firstIndex(where: { $0.id == topic }) { threads[i].unreadCount = 0 }
        Task { await client.markRead(chat: bot.chatID, topic: topic, messages: [last.id]) }
    }

    // MARK: - Replies (design-rules 16)

    /// Originals fetched for a reply, outside the loaded history; ids found gone.
    private var originals: [MessageID: ChatMessage] = [:]
    private var goneOriginals: Set<MessageID> = []
    private var fetchingOriginals: Set<MessageID> = []

    /// What `m` shows above itself when it replies to another message: from the loaded history,
    /// else fetched once (`.loading` until then), `.deleted` when the original is gone.
    public func replyPreview(for m: ChatMessage) -> ReplyPreview? {
        guard let id = m.replyTo else { return nil }
        if let o = messages[m.topic]?.first(where: { $0.id == id }) ?? originals[id] { return ReplyPreview(original: o) }
        if goneOriginals.contains(id) { return ReplyPreview(originalID: id, content: .deleted) }
        Task { await fetchOriginal(id) }
        return ReplyPreview(originalID: id, content: .loading)
    }

    func fetchOriginal(_ id: MessageID) async {
        guard let bot, !fetchingOriginals.contains(id), originals[id] == nil, !goneOriginals.contains(id) else { return }
        fetchingOriginals.insert(id)
        defer { fetchingOriginals.remove(id) }
        do {
            if let o = try await client.message(chat: bot.chatID, id: id) { originals[id] = o } else { goneOriginals.insert(id) }
        } catch {}
    }

    /// Loads older pages of `topic` until `id` is in the history, so the transcript can scroll to
    /// it without a gap. False when the original is gone (or too far back to page to).
    public func loadAround(_ id: MessageID, in topic: TopicID) async -> Bool {
        func loaded() -> Bool { messages[topic]?.contains { $0.id == id } ?? false }
        if loaded() { return true }
        if goneOriginals.contains(id) { return false }
        for _ in 0..<Self.maxPagesToOriginal where !loaded() && !reachedStart.contains(topic) {
            let before = messages[topic]?.count ?? 0
            await loadOlder(topic)
            if (messages[topic]?.count ?? 0) == before { break }
        }
        if !loaded() { await fetchOriginal(id) }
        return loaded()
    }

    static let maxPagesToOriginal = 20

    public func send(_ text: String, in topic: TopicID, files: [URL] = [], replyTo: MessageID? = nil) async throws {
        guard let bot else { throw TelegramError.notReady }
        let limit = client.uploadLimit
        var links: [FileLink] = []
        var telegramFiles: [URL] = []
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if size > limit { links.append(try await uploadBig(file, size: size)) } else { telegramFiles.append(file) }
        }
        let body = FileLink.append(links, to: text)
        for (i, file) in telegramFiles.enumerated() {
            // The text goes as the last file's caption, as Telegram's own apps do.
            let caption = i == telegramFiles.count - 1 ? body : ""
            insert(try await client.sendFile(at: file, caption: caption, chat: bot.chatID, topic: topic))
        }
        if telegramFiles.isEmpty, !body.isEmpty {
            insert(try await client.send(text: body, chat: bot.chatID, topic: topic, replyTo: replyTo))
        }
    }

    private func uploadBig(_ file: URL, size: Int64) async throws -> FileLink {
        let id = UUID()
        uploads[id] = UploadProgress(name: file.lastPathComponent, total: size, sent: 0, service: uploader.serviceName)
        defer { uploads[id] = nil }
        let url = try await uploader.upload(file: file) { [weak self] sent in
            Task { @MainActor in self?.uploads[id]?.sent = sent }
        }
        return FileLink(url: url)
    }

    public func stopDraft(in topic: TopicID) {
        guard let bot, let d = drafts[topic] else { return }
        Task { try? await client.stopDraft(chat: bot.chatID, topic: topic, draftID: d.draftID) }
    }

    public func userIsTyping(in topic: TopicID) {
        guard let bot else { return }
        Task { await client.setTyping(chat: bot.chatID, topic: topic) }
    }

    // MARK: - Commands (protocol §2.4)

    public func commandContext(_ topic: TopicID) -> CommandContext {
        let sub = subchat(topic)
        return CommandContext(topic: topic, isEncrypted: sub?.encrypted ?? false, isUnlocked: sub?.unlocked ?? false)
    }

    /// Sends a command as the owner, in the chat it applies to; Hermes answers there and the
    /// `controls` slot then shows the new value.
    public func run(command text: String, in topic: TopicID) async throws {
        try await send(text, in: topic)
    }

    public func setPermissionMode(_ id: String) async throws {
        guard let text = controls.permissionMode?.command(for: id) else { return }
        try await run(command: text, in: .main)
    }

    public func setModel(_ model: ModelRef, in topic: TopicID) async throws {
        guard let text = controls.model?.command(for: model, in: topic) else { return }
        try await run(command: text, in: topic)
    }

    // MARK: - Sub-chats

    /// The bot creates topics (users can't, in a bot DM): ask it in the main chat.
    public func createSubchat(name: String, preset: String?) async throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = ["/sub new", preset, cleaned.isEmpty ? nil : cleaned].compactMap { $0 }.joined(separator: " ")
        try await send(command, in: .main)
    }

    /// Sends `/sub unlock` in the topic then deletes it (protocol §4).
    public func unlockSubchat(_ topic: TopicID, passphrase: String) async throws {
        guard let bot else { throw TelegramError.notReady }
        let sent = try await client.send(text: "/sub unlock \(passphrase)", chat: bot.chatID, topic: topic, replyTo: nil)
        try? await Task.sleep(for: .seconds(1.5))
        try? await client.delete(messages: [sent.id], chat: bot.chatID)
        messages[topic]?.removeAll { $0.text.text.hasPrefix("/sub unlock") }
    }

    public func lockSubchat(_ topic: TopicID) async throws {
        try await send("/sub lock", in: topic)
    }

    // MARK: - Questions

    /// Presses the button behind `option`: the `data_b64` from the state, else the keyboard
    /// button with the same label in the question's message.
    public func answer(_ question: PendingQuestion, with option: QuestionOption) async throws -> String? {
        guard let bot else { throw TelegramError.notReady }
        guard let messageID = question.messageID else { throw TelegramError.server(code: 400, message: L("This question has no message.")) }
        var data = option.data
        if data == nil {
            let message = messages[question.chat]?.first { $0.id == messageID }
            if case .callback(let d)? = message?.buttons.first(where: { $0.label == option.label })?.action { data = d }
        }
        guard let data else { throw TelegramError.server(code: 400, message: L("This button can't be pressed from here.")) }
        let toast = try await client.pressButton(chat: bot.chatID, message: messageID, data: data)
        state.questions.removeAll { $0.id == question.id }
        petReaction = .jumping
        hooks.stateChanged(state)
        return toast
    }

    public func press(_ button: InlineButton, on message: ChatMessage) async throws -> String? {
        guard let bot, case .callback(let data) = button.action else { return nil }
        return try await client.pressButton(chat: bot.chatID, message: message.id, data: data)
    }

    // MARK: - App topic

    private func loadAppTopic(_ topic: TopicID) async {
        guard let bot else { return }
        guard let page = try? await client.history(chat: bot.chatID, topic: topic, from: 0, limit: 100) else { return }
        // Newest first: the first message of each slot type wins.
        for m in page.reversed() { handleAppMessage(m, replay: true) }
    }

    func handleAppMessage(_ m: ChatMessage, replay: Bool = false) {
        if m.isOutgoing {
            return
        }
        if let doc = m.attachment, m.id == slotIDs["sprite"] ?? state.slots["sprite"] ?? state.pet?.spriteMessageID {
            fetchSprite(doc)
            return
        }
        guard let message = AppProtocol.decode(m.text.text) else { return }
        switch message {
        case .state(let s):
            guard m.id >= (slotIDs["state"] ?? 0) else { return }
            slotIDs["state"] = m.id
            let oldSprite = state.pet?.spriteMessageID
            state = s
            // The pet looks toward a question as it arrives: not one replayed at launch, nor one
            // answered here that a lagging state still lists.
            let ids = Set(s.questions.map(\.id))
            if !replay, !ids.isSubset(of: seenQuestions) { petReaction = .waving }
            seenQuestions = seenQuestions.count > 500 ? ids : seenQuestions.union(ids)
            hooks.stateChanged(s)
            if let spriteID = s.pet?.spriteMessageID ?? s.slots["sprite"], spriteID != oldSprite || spriteURL == nil {
                loadSprite(messageID: spriteID)
            }
        case .stats(let s):
            guard m.id >= (slotIDs["stats"] ?? 0) else { return }
            slotIDs["stats"] = m.id
            stats = s
            hooks.statsChanged(s)
        case .devices(let d):
            guard m.id >= (slotIDs["devices"] ?? 0) else { return }
            slotIDs["devices"] = m.id
            delivery = d
        case .controls(let c):
            guard m.id >= (slotIDs["controls"] ?? 0) else { return }
            slotIDs["controls"] = m.id
            controls = c
        case .notify(let n):
            // History replays old notifications: only live ones become banners.
            guard !replay else { return }
            hooks.notify(n)
            ack([m.id])
        case .reply(let r):
            guard let re = r.re else { return }
            if let c = pendingReplies.removeValue(forKey: re) { c.resume(returning: r) }
            else { earlyReplies[re] = r }
            if !replay { ack([m.id]) }
        case .other:
            break
        }
    }

    private func ack(_ ids: [MessageID]) {
        Task { _ = try? await sendRequest(.ack(ids), awaitReply: false) }
    }

    private func loadSprite(messageID: MessageID) {
        guard let bot, let appTopicID else { return }
        Task {
            guard let page = try? await client.history(chat: bot.chatID, topic: appTopicID, from: messageID + 1, limit: 5),
                  let m = page.first(where: { $0.id == messageID }), let doc = m.attachment else { return }
            fetchSprite(doc)
        }
    }

    private func fetchSprite(_ doc: FileAttachment) {
        Task {
            guard let url = try? await client.download(fileID: doc.fileID) else { return }
            spriteURL = url
            if let pet = state.pet { hooks.spriteAvailable(pet, url) }
        }
    }

    private var requestIDs: [MessageID: MessageID] = [:]

    /// Sends a request in the App topic and waits for its `reply` (by the request's message id).
    @discardableResult
    public func sendRequest(_ request: AppRequest, awaitReply: Bool = true, timeout: Duration = .seconds(30)) async throws -> ReplyPayload? {
        guard let bot, let appTopicID else { throw TelegramError.notReady }
        let sent = try await client.send(text: AppProtocol.encode(request), chat: bot.chatID, topic: appTopicID, replyTo: nil)
        guard awaitReply else { return nil }
        // A local message's id changes once Telegram accepts it: wait for the server id.
        let serverID = try await serverMessageID(for: sent.id, pending: sent.sendState == .pending)
        if let early = earlyReplies.removeValue(forKey: serverID) { return early }
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.pendingReplies.removeValue(forKey: serverID)?
                .resume(throwing: TelegramError.server(code: 408, message: L("Hermes didn't answer in time.")))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in pendingReplies[serverID] = c }
    }

    private var sentWaiters: [MessageID: CheckedContinuation<MessageID, Never>] = [:]

    private func serverMessageID(for localID: MessageID, pending: Bool) async throws -> MessageID {
        guard pending else { return localID }
        if let resolved = requestIDs.removeValue(forKey: localID) { return resolved }
        return await withCheckedContinuation { c in sentWaiters[localID] = c }
    }

    private func resolveSentRequest(oldID: MessageID, newID: MessageID) {
        if let c = sentWaiters.removeValue(forKey: oldID) { c.resume(returning: newID) }
        else { requestIDs[oldID] = newID }
    }

    private func sayHello() async {
        let info = Bundle.main.infoDictionary
        _ = try? await sendRequest(.hello(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
            build: info?["CFBundleVersion"] as? String ?? "0",
            device: config.deviceName,
            petVersion: BundledPet.load()?.manifest.version), awaitReply: false)
    }

    // MARK: - Pet

    /// A stroke or long press on the pet: a happy reaction, here only. Hermes isn't told: it
    /// would be a Telegram message per stroke for nothing Hermes acts on, and no counter is kept.
    public func caress() {
        petReaction = .jumping
        caressedAt = .now
    }

    public func refreshStats() {
        Task { _ = try? await sendRequest(.statsRefresh, awaitReply: false) }
    }

    /// Tells Hermes a call is on (spoken style for every turn) or over.
    public func setCallActive(_ active: Bool) async {
        _ = try? await sendRequest(.callState(active: active), awaitReply: false)
    }

    /// One utterance of a call, as a main-chat message Hermes answers like any other.
    public func sendCallTurn(_ transcript: String, in topic: TopicID = .main) async throws {
        try await send(CallTurn.message(for: transcript), in: topic)
    }

    public func logOut() async {
        try? await client.logOut()
        bot = nil
        threads = []
        messages = [:]
        drafts = [:]
        state = AppState()
        stats = nil
    }

    // MARK: - Login

    public func submitPhone(_ phone: String) async throws { try await client.setPhoneNumber(phone) }
    public func submitCode(_ code: String) async throws { try await client.checkCode(code) }
    public func resendCode() async throws { try await client.resendCode() }
    public func submitPassword(_ password: String) async throws { try await client.checkPassword(password) }

    // Test seam: feed events without a client loop.
    public func _apply(_ event: TelegramEvent) { handle(event) }
    public func _setBot(_ bot: BotChat, appTopic: TopicID?) {
        self.bot = bot
        self.appTopicID = appTopic
    }
}

public struct UploadProgress: Sendable, Equatable {
    public var name: String
    public var total: Int64
    public var sent: Int64
    public var service: String
    public var fraction: Double { total > 0 ? Double(sent) / Double(total) : 0 }
}
