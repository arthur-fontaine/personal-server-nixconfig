import Foundation

/// TDLib stand-in over fixtures: the demo mode (no api_id), SwiftUI previews, UI screenshots and
/// tests. It behaves like the real bot: echoes, streams a draft, edits the App slots.
@MainActor
public final class FakeTelegramClient: TelegramClient {
    public let events: AsyncStream<TelegramEvent>
    private let continuation: AsyncStream<TelegramEvent>.Continuation
    public var uploadLimit: Int64 = 2 * 1024 * 1024 * 1024

    nonisolated public static let botChat = BotChat(chatID: 7_000_001, userID: 7_000_001, title: "Hermes", username: "hermes_bot")
    nonisolated public static let appTopic: TopicID = 90
    public var startsLoggedIn: Bool
    /// Streaming speed; tests set it to 0.
    public var streamDelay: Duration = .milliseconds(45)
    private var nextID: MessageID = 5000
    private var store: [TopicID: [ChatMessage]]
    private var appState: AppState
    private var phone = ""
    private var mode = "auto"
    private var model = "deepseek-v4.1-flash"
    private var sentLog: [String] = []

    /// `review`: the main chat ends on the backup question, Hermes' reply still streaming and its
    /// approval pending — one screen with prose, code, a draft and a question (design reviews).
    private let scene: String?

    public init(startsLoggedIn: Bool = true, withQuestion: Bool = true, scene: String? = nil, now: Date = .now) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.startsLoggedIn = startsLoggedIn
        self.scene = scene
        store = Fixtures.messages(now: now)
        appState = Fixtures.state(now: now)
        if scene == "review" {
            store[.main] = (store[.main] ?? []).filter { $0.id <= 1004 }
        }
        if !withQuestion {
            appState.questions = []
            appState.agent = AgentState(status: .idle)
            var main = store[.main] ?? []
            if let i = main.firstIndex(where: { $0.id == 1005 }) {
                main[i].buttons = []
                main[i].text = FormattedText(main[i].text.text + "\n\n✅ " + L("Allowed once"))
            }
            store[.main] = main
        }
    }

    /// What the app sent, for tests.
    public var sent: [String] { sentLog }

    public func start() {
        emit(.auth(startsLoggedIn ? .ready : .waitPhoneNumber))
        emit(.connection(.ready))
        if scene == "review" {
            Task {
                try? await Task.sleep(for: .seconds(1))
                emit(.draft(Self.botChat.chatID, StreamingDraft(draftID: 1, topic: .main, text: Markdownish.parse(Fixtures.reviewDraft), canStop: true)))
            }
        }
    }

    private func emit(_ e: TelegramEvent) { continuation.yield(e) }

    // MARK: Login

    public func setPhoneNumber(_ phone: String) async throws {
        try await Task.sleep(for: .milliseconds(500))
        guard phone.filter(\.isNumber).count >= 8 else { throw TelegramError.server(code: 400, message: "PHONE_NUMBER_INVALID") }
        self.phone = phone
        emit(.auth(.waitCode(phone: phone, via: "Telegram", length: 5, nextVia: "SMS")))
    }

    public func checkCode(_ code: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        guard code.count == 5 else { throw TelegramError.server(code: 400, message: "PHONE_CODE_INVALID") }
        emit(.auth(.waitPassword(hint: L("the usual one"))))
    }

    public func resendCode() async throws {
        emit(.auth(.waitCode(phone: phone, via: "SMS", length: 5, nextVia: nil)))
    }

    public func checkPassword(_ password: String) async throws {
        try await Task.sleep(for: .milliseconds(500))
        guard !password.isEmpty else { throw TelegramError.server(code: 400, message: "PASSWORD_HASH_INVALID") }
        emit(.auth(.ready))
    }

    public func logOut() async throws { emit(.auth(.waitPhoneNumber)) }

    // MARK: Chat

    public func findBot(username: String) async throws -> BotChat { Self.botChat }

    public func topics(in chat: ChatID) async throws -> [ChatThread] {
        Fixtures.threads.map { t in
            var t = t
            t.lastMessage = store[t.id]?.last
            return t
        }
    }

    public func history(chat: ChatID, topic: TopicID, from fromMessageID: MessageID, limit: Int) async throws -> [ChatMessage] {
        if topic == Self.appTopic { return appTopicMessages().reversed() }
        let all = store[topic] ?? []
        let older = fromMessageID == 0 ? all : all.filter { $0.id < fromMessageID }
        return Array(older.suffix(limit).reversed())
    }

    private func appTopicMessages() -> [ChatMessage] {
        [
            Fixtures.appMessage(id: 801, json: Fixtures.devicesJSON),
            Fixtures.appMessage(id: 802, json: Fixtures.statsJSON),
            Fixtures.appMessage(id: 803, json: encodeState()),
            Fixtures.appMessage(id: 804, json: Fixtures.controlsJSON(mode: mode, model: model, reasoning: "medium")),
        ]
    }

    private func encodeState() -> String { Fixtures.stateJSON(appState) }

    public func send(text: String, chat: ChatID, topic: TopicID, replyTo: MessageID?) async throws -> ChatMessage {
        sentLog.append(text)
        nextID += 1
        var local = ChatMessage(id: nextID, topic: topic, date: .now, isOutgoing: true, text: FormattedText(text))
        if topic == Self.appTopic {
            // As TDLib: a sent message is pending until the server gives it its real id.
            local.sendState = .pending
            Task { await handleRequest(text, id: local.id) }
            return local
        }
        store[topic, default: []].append(local)
        if text.hasPrefix("/mode ") { mode = String(text.dropFirst(6)); pushControls() }
        if text.hasPrefix("/model ") { model = String(text.split(separator: " ")[1]); pushControls() }
        if !text.hasPrefix("/sub unlock") { Task { await reply(to: text, in: topic) } }
        return local
    }

    public func sendFile(at url: URL, caption: String, chat: ChatID, topic: TopicID) async throws -> ChatMessage {
        nextID += 1
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let m = ChatMessage(id: nextID, topic: topic, date: .now, isOutgoing: true, text: FormattedText(caption),
                            attachment: FileAttachment(kind: .document, fileID: Int32(nextID), name: url.lastPathComponent, size: size))
        store[topic, default: []].append(m)
        return m
    }

    public func delete(messages ids: [MessageID], chat: ChatID) async throws {
        for k in store.keys { store[k]?.removeAll { ids.contains($0.id) } }
        emit(.messagesDeleted(chat, ids))
    }

    public func pressButton(chat: ChatID, message: MessageID, data: Data) async throws -> String? {
        let answer = String(decoding: data, as: UTF8.self)
        appState.questions.removeAll { $0.messageID == message }
        appState.agent = AgentState(status: .working, task: L("Running: restic backup --retry"), since: .now, chat: .main)
        pushState()
        for (topic, list) in store {
            if let i = list.firstIndex(where: { $0.id == message }) {
                var m = list[i]
                m.buttons = []
                m.text = FormattedText(m.text.text + "\n\n✅ " + (answer.contains("deny") ? L("Denied") : L("Allowed")))
                store[topic]?[i] = m
                emit(.messageChanged(chat, m))
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            appState.agent = AgentState(status: .idle)
            pushState()
        }
        return nil
    }

    public func stopDraft(chat: ChatID, topic: TopicID, draftID: Int64) async throws {
        stopped.insert(draftID)
        emit(.draftStopped(chat, topic: topic, draftID: draftID))
    }

    private var stopped: Set<Int64> = []

    public func download(fileID: Int32) async throws -> URL {
        if let pet = BundledPet.load() { return pet.spritesheet }
        throw TelegramError.notReady
    }

    public func markRead(chat: ChatID, topic: TopicID, messages: [MessageID]) async {}
    public func setTyping(chat: ChatID, topic: TopicID) async {}
    public func registerForPush(token: Data) async throws {}

    // MARK: Simulated bot

    private func reply(to text: String, in topic: TopicID) async {
        let chat = Self.botChat.chatID
        try? await Task.sleep(for: streamDelay * 6)
        appState.agent = AgentState(status: .thinking, task: nil, since: .now, chat: topic)
        pushState()
        emit(.typing(chat, topic: topic, active: true))
        try? await Task.sleep(for: streamDelay * 10)
        let answer = Fixtures.answer(to: text)
        let draftID = Int64.random(in: 1...Int64.max)
        var shown = ""
        appState.agent = AgentState(status: .working, task: L("Writing the answer"), since: .now, chat: topic)
        pushState()
        for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
            if stopped.contains(draftID) { break }
            shown += (shown.isEmpty ? "" : " ") + word
            if topic == .main {
                emit(.draft(chat, StreamingDraft(draftID: draftID, topic: topic, text: Markdownish.parse(shown), canStop: true)))
            }
            try? await Task.sleep(for: streamDelay)
        }
        nextID += 1
        let final = ChatMessage(id: nextID, topic: topic, date: .now, isOutgoing: false, text: Markdownish.parse(shown))
        store[topic, default: []].append(final)
        emit(.newMessage(chat, final))
        appState.agent = AgentState(status: .idle)
        pushState()
    }

    private func pushControls() {
        emit(.messageChanged(Self.botChat.chatID, Fixtures.appMessage(id: 804, json: Fixtures.controlsJSON(mode: mode, model: model, reasoning: "medium"))))
    }

    private func pushState() {
        emit(.messageChanged(Self.botChat.chatID, Fixtures.appMessage(id: 803, json: encodeState())))
    }

    private func handleRequest(_ text: String, id: MessageID) async {
        guard let data = AppProtocol.extractJSON(from: text),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        nextID += 1
        let serverID = nextID
        emit(.messageSent(Self.botChat.chatID, oldID: id,
                          ChatMessage(id: serverID, topic: Self.appTopic, date: .now, isOutgoing: true, text: FormattedText(text))))
        try? await Task.sleep(for: .milliseconds(300))
        var replyData = "{}"
        switch type {
        case "pet.feed", "pet.play", "pet.sleep", "pet.wake":
            if var pet = appState.pet {
                let action = PetAction(rawValue: String(type.dropFirst(4)))!
                pet = action.optimisticallyApplied(to: pet)
                pet.xp += action == .play ? 15 : 5
                appState.pet = pet
                pushState()
            }
        case "call.state":
            replyData = #"{"active":true}"#
        case "ack", "hello", "stats.refresh": if type != "stats.refresh" { return }
        default: break
        }
        nextID += 1
        emit(.newMessage(Self.botChat.chatID, Fixtures.appMessage(id: nextID, json: #"{"v":2,"type":"reply","re":\#(serverID),"ok":true,"data":\#(replyData)}"#)))
    }

    /// Scripted: a question arrives (Live Activity and banner demos).
    public func simulateApproval() {
        let chat = Self.botChat.chatID
        nextID += 1
        let m = Fixtures.approvalMessage(id: nextID, now: .now)
        store[.main, default: []].append(m)
        emit(.newMessage(chat, m))
        appState.questions = [Fixtures.approvalQuestion(messageID: m.id)]
        appState.agent = AgentState(status: .waitingUser, task: L("Waiting for your approval"), since: .now, chat: .main)
        pushState()
    }
}

/// Just enough markdown for the fake bot: **bold**, `code`, fenced blocks.
enum Markdownish {
    static func parse(_ s: String) -> FormattedText {
        var out = ""
        var entities: [TextEntity] = []
        var i = s.startIndex
        func utf16Count(_ str: String) -> Int { str.utf16.count }
        while i < s.endIndex {
            if s[i...].hasPrefix("```"), let end = s[s.index(i, offsetBy: 3)...].range(of: "```") {
                var body = String(s[s.index(i, offsetBy: 3)..<end.lowerBound])
                var lang: String?
                if let nl = body.firstIndex(of: "\n") {
                    let l = body[..<nl].trimmingCharacters(in: .whitespaces)
                    if !l.isEmpty, !l.contains(" ") { lang = l }
                    body = String(body[body.index(after: nl)...])
                }
                body = body.trimmingCharacters(in: .newlines)
                entities.append(TextEntity(offset: utf16Count(out), length: utf16Count(body), kind: .pre(language: lang)))
                out += body
                i = end.upperBound
            } else if s[i...].hasPrefix("**"), let end = s[s.index(i, offsetBy: 2)...].range(of: "**") {
                let body = String(s[s.index(i, offsetBy: 2)..<end.lowerBound])
                entities.append(TextEntity(offset: utf16Count(out), length: utf16Count(body), kind: .bold))
                out += body
                i = end.upperBound
            } else if s[i] == "`", let end = s[s.index(after: i)...].firstIndex(of: "`") {
                let body = String(s[s.index(after: i)..<end])
                entities.append(TextEntity(offset: utf16Count(out), length: utf16Count(body), kind: .code))
                out += body
                i = s.index(after: end)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return FormattedText(out, entities: entities)
    }
}
