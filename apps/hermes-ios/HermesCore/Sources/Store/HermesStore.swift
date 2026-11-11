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
    /// What the App topic last did, for Settings › About › Diagnostics.
    public private(set) var topicLog = AppTopicLog()
    private var resyncTask: Task<Void, Never>?
    public var slotMemory = SlotMemory()
    /// Dynamic UIs (§8) by their message's chat and key (UIKey), from the App topic or kept from a
    /// previous launch.
    public private(set) var uiSpecs: [UISpecMemory.Place: UISpec] = [:]
    private var uiEntries: [UISpecMemory.Place: UISpecMemory.Entry] = [:]
    public var uiMemory = UISpecMemory()
    /// What was read of Hermes' memory this session (HermesStore+Memory).
    @ObservationIgnored public internal(set) var memoryCache = MemoryCache()
    private var pendingReplies: [MessageID: CheckedContinuation<ReplyPayload, Error>] = [:]
    private var earlyReplies: [MessageID: ReplyPayload] = [:]
    private var seenQuestions: Set<String> = []
    /// A one-shot row the pet plays over its mood, then the view clears it: `.jumping` for a
    /// caress or an answered question (the nod), `.waving` toward a question that just arrived.
    public var petReaction: PetAnimation?
    /// When the owner last caressed the pet: the trigger for its haptic and heart.
    public private(set) var caressedAt: Date?
    /// When Hermes last wrote or changed state: the start of the background grace window.
    public private(set) var lastBotActivity: Date?

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
        uiEntries = uiMemory.load()
        uiSpecs = uiEntries.mapValues(\.spec)
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
        return PetAnimation.loop(status: state.agent?.status, mood: petMood)
    }
    public var questions: [PendingQuestion] { state.questions }

    public func messages(in topic: TopicID) -> [ChatMessage] { messages[topic] ?? [] }

    public func subchat(_ topic: TopicID) -> SubchatInfo? { state.subchats.first { $0.topicID == topic } }
    public func isPrivate(_ topic: TopicID) -> Bool { subchat(topic)?.encrypted ?? false }

    public func thread(_ topic: TopicID) -> ChatThread? {
        topic == .main ? mainThread : threads.first { $0.id == topic }
    }

    public func questions(in topic: TopicID) -> [PendingQuestion] { state.questions.filter { $0.chat == topic } }

    /// The open question a transcript message carries (`id` is TDLib's).
    public func question(forMessage id: MessageID) -> PendingQuestion? { state.questions.first { $0.tdlibMessageID == id } }

    /// The state's question for a message that asks: the one whose answers are its buttons, else
    /// the one naming its id.
    public func question(for message: ChatMessage) -> PendingQuestion? {
        let data = Set(message.buttons.compactMap { b -> Data? in
            if case .callback(let d) = b.action { return d } else { return nil }
        })
        return state.questions.first { q in q.options.contains { $0.data.map(data.contains) == true } }
            ?? question(forMessage: message.id)
    }

    public var isReady: Bool { auth == .ready && bot != nil }

    // MARK: - Events

    func handle(_ event: TelegramEvent) {
        switch event {
        case .auth(let a):
            auth = a
            if a == .ready { connectBot() }
        case .connection(let c):
            // Edits made while offline may never come as updates: read the slots again.
            if c == .ready, connection != .ready, bot != nil { Task { await resyncAppTopic() } }
            connection = c
        case .newMessage(let chat, let m):
            guard chat == bot?.chatID else { return }
            if m.topic == appTopicID { handleAppMessage(m); return }
            // The real message replaces its draft even when the message itself is hidden.
            if !m.isOutgoing { drafts[m.topic] = nil; typing.remove(m.topic); lastBotActivity = .now }
            guard let m = Self.prepared(m) else { return }
            insert(m)
            // The real message replaces the draft that streamed it.
            if !m.isOutgoing { drafts[m.topic] = nil; typing.remove(m.topic) }
            bumpThread(m)
        case .messageChanged(let chat, let m):
            guard chat == bot?.chatID else { return }
            if m.topic == appTopicID { handleAppMessage(m); return }
            guard let m = Self.prepared(m) else {
                messages[m.topic]?.removeAll { $0.id == m.id }
                return
            }
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
            var d = d
            d.text = MessageCleanup.shown(d.text).text
            drafts[d.topic] = d
            lastBotActivity = .now
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
                topicLog.note("App topic: \(appTopicID.map(String.init) ?? "none")")
                // The App topic first and on its own: the slots and hello never wait on the
                // transcript's history (build 202611091023 never got as far as hello).
                if let appTopicID { Task { await loadAppTopic(appTopicID) } }
                Task { await sayHello() }
                startResyncLoop()
                await loadHistory(.main)
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

    /// Hermes' messages as the app shows them (`MessageCleanup`): no `🔊` line, the `📎` marker
    /// turned into `isCallDetails`; nil for the steer notice, which the owner's bubble shows instead.
    static func prepared(_ m: ChatMessage) -> ChatMessage? {
        guard !m.isOutgoing else { return m }
        if MessageCleanup.isSteerNotice(m.text.text) { return nil }
        var m = m
        (m.text, m.isCallDetails) = MessageCleanup.shown(m.text)
        return m
    }

    /// The owner's message is waiting for Hermes to take it into the running turn (`state.pending`).
    public func isWaiting(_ m: ChatMessage) -> Bool {
        m.isOutgoing && state.pending.contains { BotAPIID.tdlib($0.messageID) == m.id }
    }

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
            let raw = try await client.history(chat: bot.chatID, topic: topic, from: 0, limit: 50)
            let page = raw.compactMap(Self.prepared)
            let existing = messages[topic] ?? []
            let ids = Set(page.map(\.id))
            messages[topic] = (page.reversed() + existing.filter { !ids.contains($0.id) }).sorted { $0.id < $1.id }
            if raw.count < 50 { reachedStart.insert(topic) }
            if topic == .main, let last = messages[topic]?.last { mainThread.lastMessage = last }
        } catch {}
    }

    public func loadOlder(_ topic: TopicID) async {
        guard let bot, !reachedStart.contains(topic), let oldest = messages[topic]?.first else { return }
        do {
            let page = try await client.history(chat: bot.chatID, topic: topic, from: oldest.id, limit: 50)
            let fresh = page.filter { $0.id < oldest.id }
            if fresh.isEmpty { reachedStart.insert(topic); return }
            messages[topic] = fresh.compactMap(Self.prepared).reversed() + (messages[topic] ?? [])
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
            if let o = try await client.message(chat: bot.chatID, id: id).flatMap(Self.prepared) { originals[id] = o } else { goneOriginals.insert(id) }
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
    static let notifyReplayWindow: TimeInterval = 60 * 60

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
        guard let messageID = question.tdlibMessageID else { throw TelegramError.server(code: 400, message: L("This question has no message.")) }
        var data = option.data
        if data == nil {
            let message = messages[question.chat]?.first { $0.id == messageID }
            // The keyboard's label, as the state sent it (the card may show a choice's text instead).
            let label = state.questions.first { $0.id == question.id }?.options.first { $0.id == option.id }?.label ?? option.label
            if case .callback(let d)? = message?.buttons.first(where: { $0.label == label || $0.label == option.label })?.action { data = d }
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
        let toast = try await client.pressButton(chat: bot.chatID, message: message.id, data: data)
        // An answer: the question leaves the state now (Live Activity, notifications) rather than
        // at the server's next state.
        let before = state.questions.count
        state.questions.removeAll { q in q.tdlibMessageID == message.id || q.options.contains { $0.data == data } }
        if state.questions.count != before {
            petReaction = .jumping
            hooks.stateChanged(state)
        }
        return toast
    }

    // MARK: - App topic

    private func loadAppTopic(_ topic: TopicID) async {
        guard let bot else { return }
        // Last launch's slot ids first: the state shows even when the history never answers.
        await resyncAppTopic()
        do {
            let page = try await Self.withTimeout(Self.topicTimeout) { [client] in
                try await client.history(chat: bot.chatID, topic: topic, from: 0, limit: 100)
            }
            topicLog.note("history: \(page.count) messages")
            // Oldest first, so the newest message of each slot type wins.
            for m in page.sorted(by: { $0.id < $1.id }) { handleAppMessage(m, replay: true) }
            // The slots are old messages the server only edits: often more than a page back.
            // Page back until each one is found, whatever the server answers to hello.
            var oldest = page.map(\.id).min()
            var pages = 1
            while let from = oldest, pages < 30, !Self.slotNames.isSubset(of: Set(slotIDs.keys)) {
                let older = try await Self.withTimeout(Self.topicTimeout) { [client] in
                    try await client.history(chat: bot.chatID, topic: topic, from: from, limit: 100)
                }.filter { $0.id < from }
                guard !older.isEmpty else { break }
                for m in older.sorted(by: { $0.id < $1.id }) { handleAppMessage(m, replay: true) }
                oldest = older.map(\.id).min()
                pages += 1
            }
            topicLog.note("history: \(pages) page(s), slots found: \(slotIDs.keys.sorted().joined(separator: ", "))")
        } catch {
            topicLog.fail("history: \(error.localizedDescription)")
        }
        await resyncAppTopic()
    }

    /// Reads each slot message by its id. The slots are old messages the server only edits, and
    /// TDLib sends edit updates only for messages it has loaded: after a relaunch, a lost
    /// connection or a history page that missed them, no update ever comes. Reading them by id
    /// loads them into TDLib, so their later edits arrive too.
    public func resyncAppTopic() async {
        guard let appTopicID else { return }
        var ids = Set(slotIDs.values)
        for (name, id) in state.slots where name != "sprite" { ids.insert(BotAPIID.tdlib(id)) }
        if ids.isEmpty { ids = Set(slotMemory.load(topic: appTopicID).map(BotAPIID.tdlib)) }
        await readSlots(Array(ids))
    }

    /// Reads App topic messages by their TDLib ids and applies them.
    func readSlots(_ ids: [MessageID]) async {
        guard let bot else { return }
        for id in Set(ids).sorted() {
            do {
                let found = try await Self.withTimeout(Self.topicTimeout) { [client] in try await client.message(chat: bot.chatID, id: id) }
                if let m = found { handleAppMessage(m, replay: true) }
                else { topicLog.fail("slot \(BotAPIID.botAPI(id) ?? id) is gone") }
            } catch {
                topicLog.fail("slot \(BotAPIID.botAPI(id) ?? id): \(error.localizedDescription)")
            }
        }
    }

    private func startResyncLoop() {
        guard resyncTask == nil else { return }
        resyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.resyncEvery)
                guard let self, self.connection == .ready else { continue }
                await self.resyncAppTopic()
            }
        }
    }

    static let slotNames: Set<String> = ["state", "stats", "devices", "controls"]
    static let resyncEvery: Duration = .seconds(30)
    static var topicTimeout: Duration = .seconds(15)

    struct Timeout: LocalizedError {
        var errorDescription: String? { "no answer from Telegram" }
    }

    /// TDLib answers every request, but a request it never answers must not hold the App topic
    /// (or hello) behind it.
    static func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: limit); throw Timeout() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func handleAppMessage(_ m: ChatMessage, replay: Bool = false) {
        if m.isOutgoing {
            return
        }
        if let doc = m.attachment, let sprite = state.slots["sprite"] ?? state.pet?.spriteMessageID, m.id == BotAPIID.tdlib(sprite) {
            fetchSprite(doc)
            return
        }
        let message: DecodedAppMessage
        switch AppProtocol.decodeResult(m.text.text) {
        case .success(let decoded):
            message = decoded
        case .failure(let failure):
            // A message that isn't protocol JSON at all (someone typing in the topic) is no error.
            if failure != .notJSON { topicLog.fail("message \(BotAPIID.botAPI(m.id) ?? m.id): \(failure)") }
            return
        }
        if let v = message.version, v > AppProtocol.version { topicLog.note("server speaks protocol v\(v), app v\(AppProtocol.version)") }
        if let kind = message.slotName { topicLog.decoded(kind, id: BotAPIID.botAPI(m.id) ?? m.id) }
        switch message.payload {
        case .state(let s):
            guard m.id >= (slotIDs["state"] ?? 0) else { return }
            slotIDs["state"] = m.id
            rememberSlots()
            let oldSprite = state.pet?.spriteMessageID
            if !replay, s.agent != state.agent || s.questions != state.questions { lastBotActivity = .now }
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
            rememberSlots()
            stats = s
            hooks.statsChanged(s)
        case .devices(let d):
            guard m.id >= (slotIDs["devices"] ?? 0) else { return }
            slotIDs["devices"] = m.id
            rememberSlots()
            delivery = d
        case .controls(let c):
            guard m.id >= (slotIDs["controls"] ?? 0) else { return }
            slotIDs["controls"] = m.id
            rememberSlots()
            controls = c
        case .notify(let n):
            // A replay (launch, or a relaunch by background refresh) shows what arrived while the
            // app was gone: notifies still here weren't acked, so not shown. Older than an hour,
            // the bot is about to delete them and they are news no more. The hook posts each once.
            guard !replay || m.date > .now.addingTimeInterval(-Self.notifyReplayWindow) else { return }
            hooks.notify(n)
            ack([m.id])
        case .reply(let r):
            guard let re = r.re else { return }
            if !r.ok { topicLog.fail("request \(re): \(r.errorCode ?? "?") \(r.errorMessage ?? "")") }
            // `re` is the request's Bot API id; requests are waited on by their TDLib id.
            let request = BotAPIID.tdlib(re)
            if let c = pendingReplies.removeValue(forKey: request) { c.resume(returning: r) }
            else { earlyReplies[request] = r }
            if !replay { ack([m.id]) }
        case .ui(let e):
            guard !e.key.isEmpty else { topicLog.fail("ui \(e.messageID): no key"); return }
            let target = UISpecMemory.Place(chat: e.chat, key: e.key)
            guard m.id >= (uiEntries[target]?.source ?? 0) else { return }
            if let spec = e.spec {
                setUISpec(spec, for: target, source: m.id)
            } else if let doc = m.attachment {
                fetchUISpec(doc, for: target, source: m.id)
            } else {
                topicLog.fail("ui \(e.messageID): no spec")
            }
        case .other:
            break
        }
    }

    // MARK: - Dynamic UI (§8)

    /// The UI to draw for one of Hermes' messages, if it has one.
    public func uiSpec(for message: ChatMessage) -> UISpec? {
        guard !message.isOutgoing else { return nil }
        let key = UIKey.of(message.displayText)
        return key.isEmpty ? nil : uiSpecs[UISpecMemory.Place(chat: message.topic, key: key)]
    }

    /// A UI's `reply` action: the text as the owner's reply to the UI's message.
    public func reply(_ text: String, to message: ChatMessage) async throws {
        try await send(text, in: message.topic, replyTo: message.id)
    }

    private func setUISpec(_ spec: UISpec, for place: UISpecMemory.Place, source: MessageID) {
        guard source >= (uiEntries[place]?.source ?? 0) else { return }
        uiEntries[place] = UISpecMemory.Entry(source: source, spec: spec)
        uiSpecs[place] = spec
        uiMemory.save(uiEntries)
    }

    /// A spec too big for a message comes as a `ui.json` document (§8).
    private func fetchUISpec(_ doc: FileAttachment, for place: UISpecMemory.Place, source: MessageID) {
        Task {
            do {
                let url = try await client.download(fileID: doc.fileID)
                guard let spec = UISpec.decode(try Data(contentsOf: url)) else {
                    topicLog.fail("ui \(place.key): ui.json is not a spec")
                    return
                }
                setUISpec(spec, for: place, source: source)
            } catch {
                topicLog.fail("ui \(place.key): \(error.localizedDescription)")
            }
        }
    }

    private func rememberSlots() {
        guard let appTopicID else { return }
        slotMemory.save(topic: appTopicID, ids: slotIDs.values.compactMap(BotAPIID.botAPI))
    }

    private func ack(_ ids: [MessageID]) {
        let serverIDs = ids.compactMap(BotAPIID.botAPI)
        guard !serverIDs.isEmpty else { return }
        Task { _ = try? await sendRequest(.ack(serverIDs), awaitReply: false) }
    }

    /// `messageID`: the protocol's (Bot API) id of the message holding the spritesheet.
    private func loadSprite(messageID botAPIID: MessageID) {
        guard let bot, let appTopicID else { return }
        let messageID = BotAPIID.tdlib(botAPIID)
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
        do {
            let reply = try await sendRequest(.hello(
                appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
                build: info?["CFBundleVersion"] as? String ?? "0",
                device: config.deviceName,
                petVersion: BundledPet.load()?.manifest.version))
            topicLog.note("hello answered")
            // The server names its slot messages: they are old and only edited, often more than a
            // history page back, so read them by id rather than wait to page back to them.
            if case .object(let data)? = reply?.fields["data"], case .object(let slots)? = data["slots"] {
                let ids = slots.compactMap { name, value -> MessageID? in
                    guard name != "sprite", case .number(let n) = value else { return nil }
                    return BotAPIID.tdlib(MessageID(n))
                }
                await readSlots(ids)
            }
        } catch {
            topicLog.fail("hello: \(error.localizedDescription)")
        }
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
        uiSpecs = [:]
        uiEntries = [:]
        uiMemory.save([:])
        forgetMemory()
    }

    // MARK: - Login

    public func submitPhone(_ phone: String) async throws { try await client.setPhoneNumber(phone) }
    public func submitCode(_ code: String) async throws { try await client.checkCode(code) }
    public func resendCode() async throws { try await client.resendCode() }
    public func submitPassword(_ password: String) async throws { try await client.checkPassword(password) }

    // Test seam: feed events without a client loop.
    public func _apply(_ event: TelegramEvent) { handle(event) }
    public func _loadUIMemory() {
        uiEntries = uiMemory.load()
        uiSpecs = uiEntries.mapValues(\.spec)
    }
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
