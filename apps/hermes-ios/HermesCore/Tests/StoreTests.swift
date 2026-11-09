import Foundation
import Testing
@testable import HermesCore

@MainActor
@Suite("HermesStore over the fake client")
struct StoreTests {
    func makeStore(loggedIn: Bool = true) async throws -> (HermesStore, FakeTelegramClient) {
        let client = FakeTelegramClient(startsLoggedIn: loggedIn)
        client.streamDelay = .milliseconds(1)
        let store = HermesStore(client: client, config: .preview)
        store.start()
        if loggedIn { try await waitUntil { store.isReady && store.state.pet != nil } }
        return (store, client)
    }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func loadsTopicsHidesAppAndReadsSlots() async throws {
        let (store, _) = try await makeStore()
        #expect(store.appTopicID == FakeTelegramClient.appTopic)
        #expect(!store.threads.contains { $0.name == "App" })
        #expect(store.threads.count == 4)
        #expect(store.messages(in: .main).count == 10)
        try await waitUntil { store.stats != nil && !store.delivery.devices.isEmpty }
        #expect(store.isPrivate(31))
        #expect(!store.isPrivate(12))
        #expect(store.questions.first?.messageID == 1005)
        #expect(store.question(forMessage: Fixtures.id(1005))?.id == "ea:7")
    }

    @Test func streamsADraftThenReplacesItWithTheMessage() async throws {
        let (store, _) = try await makeStore()
        try await store.send("hello", in: .main)
        #expect(store.messages(in: .main).last?.isOutgoing == true)
        try await waitUntil { store.drafts[.main] != nil }
        let before = store.messages(in: .main).count
        try await waitUntil { store.drafts[.main] == nil && store.messages(in: .main).count == before + 1 }
        #expect(store.messages(in: .main).last?.isOutgoing == false)
        #expect(store.agent.status == .idle)
    }

    @Test func newestSlotWinsAndOlderEditsAreIgnored() async throws {
        let (store, _) = try await makeStore()
        let chat = FakeTelegramClient.botChat.chatID
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 900, json: #"{"v":1,"type":"state","agent":{"status":"error"}}"#)))
        #expect(store.agent.status == .error)
        store._apply(.messageChanged(chat, Fixtures.appMessage(id: 803, json: #"{"v":1,"type":"state","agent":{"status":"working"}}"#)))
        #expect(store.agent.status == .error)
        #expect(store.petMood == .idle)
    }

    @Test func answeringPressesTheButtonData() async throws {
        let (store, client) = try await makeStore()
        let q = try #require(store.questions.first)
        _ = try await store.answer(q, with: q.options[0])
        #expect(store.questions.isEmpty)
        try await waitUntil { store.messages(in: .main).first { $0.id == Fixtures.id(1005) }?.buttons.isEmpty == true }
        _ = client
    }

    /// Arthur's "Message not found": the state names the keyboard's message by its Bot API id; the
    /// button must be pressed on TDLib's id for it (server id << 20), in the bot's DM.
    @Test func answeringPressesOnTDLibsIDForTheMessage() async throws {
        let (store, client) = try await makeStore()
        let chat = FakeTelegramClient.botChat.chatID
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 907, json: #"{"v":4,"type":"state","agent":{"status":"waiting_user"},"questions":[{"id":"cl:9","kind":"clarify","chat":0,"message_id":1005,"text":"Which?","options":[{"id":"a","label":"A","data_b64":"YQ=="}]}]}"#)))
        let q = try #require(store.questions.first { $0.id == "cl:9" })
        _ = try await store.answer(q, with: q.options[0])
        #expect(client.pressed.last?.message == 1005 << 20 && client.pressed.last?.chat == chat)
        #expect(client.pressed.last?.data == Data("a".utf8))
    }

    /// `chat: 0` is the main chat (protocol §1), not a topic: the card shows there, and with no
    /// `data_b64` the keyboard is read from the main chat's message, pressed on TDLib's id in the DM.
    @Test func chatZeroIsTheMainChat() async throws {
        let (store, client) = try await makeStore()
        let chat = FakeTelegramClient.botChat.chatID
        let once = try #require(store.messages(in: .main).first { $0.id == Fixtures.id(1005) }?.buttons.first?.label)
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 908, json: #"{"v":4,"type":"state","agent":{"status":"waiting_user"},"questions":[{"id":"ea:8","kind":"approval","chat":0,"message_id":1005,"text":"?","options":[{"id":"once","label":"\#(once)"}]}]}"#)))
        let q = try #require(store.questions.first { $0.id == "ea:8" })
        #expect(q.chat == .main && store.questions(in: .main).contains(q))
        #expect(!store.threads.contains { thread in thread.id != .main && store.questions(in: thread.id).contains(q) })
        _ = try await store.answer(q, with: q.options[0])
        #expect(client.pressed.last?.message == 1005 << 20 && client.pressed.last?.chat == chat)
        #expect(client.pressed.last?.data == Data("ea:once:7".utf8))
    }

    @Test func protocolIDsConvertToTDLibs() {
        #expect(BotAPIID.tdlib(1201) == 1_259_339_776)
        #expect(BotAPIID.botAPI(1_259_339_776) == 1201)
        #expect(BotAPIID.botAPI(1_259_339_777) == nil, "a local, not yet sent message has no server id")
    }

    @Test func repliesAreMatchedToRequestsByBotAPIID() async throws {
        let (store, _) = try await makeStore()
        // The fake replies with `re` = the request's server id, as the plugin does.
        let reply = try await store.sendRequest(.callState(active: true), timeout: .seconds(3))
        #expect(reply?.ok == true)
    }

    @Test func answeringFallsBackToTheKeyboardByLabel() async throws {
        let (store, _) = try await makeStore()
        var q = try #require(store.questions.first)
        q.options = q.options.map { QuestionOption(id: $0.id, label: $0.label, data: nil) }
        _ = try await store.answer(q, with: q.options[3])
        #expect(store.questions.isEmpty)
    }

    @Test func notifyReachesTheHookOnlyWhenLive() async throws {
        let (store, client) = try await makeStore()
        var received: [NotifyPayload] = []
        store.hooks.notify = { received.append($0) }
        let chat = FakeTelegramClient.botChat.chatID
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 950, json: #"{"v":1,"type":"notify","chat":0,"message_id":1,"body":"Hi","spoken":"Hi there"}"#)))
        #expect(received.map(\.speechText) == ["Hi there"])
        // A call's written detail notifies, and is never spoken.
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 951, json: #"{"v":4,"type":"notify","chat":0,"message_id":2,"body":"📎 https://example.com","spoken":""}"#)))
        #expect(received.last?.speechText == nil && received.last?.shownText == "https://example.com")
        // …and the notify message is acked so the bot deletes it.
        try await waitUntil { client.sent.contains { $0.contains("\"ack\"") && $0.contains("950") } }
    }

    @Test func aCaressStaysInTheApp() async throws {
        let (store, client) = try await makeStore()
        let sent = client.sent.count
        store.caress()
        #expect(store.petReaction == .jumping && store.petAnimation == .jumping && store.caressedAt != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(client.sent.count == sent)
    }

    @Test func thePetWavesAtANewQuestionAndNodsAtTheAnswer() async throws {
        let (store, _) = try await makeStore()
        let chat = FakeTelegramClient.botChat.chatID
        store.petReaction = nil
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 905, json: #"{"v":3,"type":"state","agent":{"status":"waiting_user"},"questions":[{"id":"cl:new","kind":"clarify","chat":0,"message_id":1005,"text":"Which?","options":[{"id":"a","label":"A","data_b64":"YQ=="}]}]}"#)))
        #expect(store.petReaction == .waving && store.petMood == .waiting)
        store.petReaction = nil
        let q = try #require(store.questions.first { $0.id == "cl:new" })
        _ = try await store.answer(q, with: q.options[0])
        #expect(store.petReaction == .jumping)
    }

    @Test func aFinishedTurnGivesAHappyBeat() async throws {
        let (store, _) = try await makeStore()
        let chat = FakeTelegramClient.botChat.chatID
        let until = ISO8601DateFormatter().string(from: .now.addingTimeInterval(10))
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 906, json: #"{"v":3,"type":"state","agent":{"status":"idle"},"pet":{"id":"pip","mood":"happy","animation":"jump","mood_until":"\#(until)"}}"#)))
        #expect(store.petMood == .happy && store.petAnimation == .jumping)
    }

    @Test func callTurnsAreMarkedMainChatMessages() async throws {
        let (store, client) = try await makeStore()
        await store.setCallActive(true)
        try await store.sendCallTurn("what's the weather in Lisbon")
        #expect(client.sent.contains("🎙 what's the weather in Lisbon"))
        try await waitUntil { client.sent.contains { $0.contains("call.state") } }
    }

    @Test func createAndUnlockSubchatsSendCommands() async throws {
        let (store, client) = try await makeStore()
        try await store.createSubchat(name: "Taxes", preset: "secret")
        #expect(client.sent.contains("/sub new secret Taxes"))
        try await store.unlockSubchat(31, passphrase: "pw")
        #expect(client.sent.contains("/sub unlock pw"))
        #expect(!store.messages(in: 31).contains { $0.text.text.hasPrefix("/sub unlock") })
    }

    @Test func controlsSetValuesBySendingCommandsInTheirChat() async throws {
        let (store, client) = try await makeStore()
        try await waitUntil { store.controls.permissionMode != nil }
        #expect(store.controls.permissionMode?.value == "auto")
        try await store.setPermissionMode("ask")
        #expect(client.sent.contains("/mode ask"))
        try await waitUntil { store.controls.permissionMode?.value == "ask" }
        let luna = try #require(store.controls.model?.chain.first { $0.role == "fallback" })
        try await store.setModel(luna, in: .main)
        #expect(client.sent.contains("/model gpt-5.5 --provider openai-codex"))
        try await waitUntil { store.controls.model?.selected(in: .main)?.model == "gpt-5.5" }
        try await store.setModel(luna, in: 12)
        #expect(client.sent.contains("/sub set model openai-codex:gpt-5.5"))
    }

    @Test func bigFilesGoThroughTheUploader() async throws {
        let client = FakeTelegramClient()
        client.uploadLimit = 10
        let uploader = StubUploader()
        let store = HermesStore(client: client, config: .preview, uploader: uploader)
        store.start()
        try await waitUntil { store.isReady }
        let file = FileManager.default.temporaryDirectory.appending(path: "big-\(UUID()).bin")
        try Data(repeating: 1, count: 64).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await store.send("the video", in: .main, files: [file])
        #expect(client.sent.last == "the video\n[fichier: https://gofile.io/d/stub]")
    }

    @Test func loginFlowGoesPhoneCodePassword() async throws {
        let (store, _) = try await makeStore(loggedIn: false)
        try await waitUntil { store.auth == .waitPhoneNumber }
        await #expect(throws: TelegramError.self) { try await store.submitPhone("12") }
        try await store.submitPhone("+33 6 12 34 56 78")
        try await waitUntil { if case .waitCode = store.auth { true } else { false } }
        try await store.submitCode("12345")
        try await waitUntil { if case .waitPassword = store.auth { true } else { false } }
        try await store.submitPassword("secret")
        try await waitUntil { store.isReady }
    }
}

struct StubUploader: BigFileUploader {
    let serviceName = "Stub"
    func upload(file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        progress(64)
        return URL(string: "https://gofile.io/d/stub")!
    }
}

@Suite("pet")
struct PetTests {
    @Test func atlasFramesFollowTheCodexLayout() {
        let layout = PetAtlasLayout.codex
        #expect(layout.frameRect(.idle, frame: 0) == CGRect(x: 0, y: 0, width: 192, height: 208))
        #expect(layout.frameRect(.review, frame: 5) == CGRect(x: 960, y: 1664, width: 192, height: 208))
        // Frames wrap at the row's own count, not the 8 columns.
        #expect(layout.frameRect(.waving, frame: 4) == layout.frameRect(.waving, frame: 0))
        #expect(PetAnimation.allCases.map(\.frameCount) == [6, 8, 8, 4, 5, 8, 6, 6, 6])
    }

    @Test func aliasesMatchHermesNames() {
        #expect(PetAnimation(alias: "run") == .running)
        #expect(PetAnimation(alias: "wave") == .waving)
        #expect(PetAnimation(alias: "jump") == .jumping)
        #expect(PetAnimation(alias: "nope") == nil)
    }

    @Test func moodMirrorsHermes() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(PetMood(agent: .working, reported: nil, until: nil, now: now) == .working)
        #expect(PetMood(agent: .thinking, reported: .happy, until: now + 5, now: now) == .working)
        #expect(PetMood(agent: .waitingUser, reported: nil, until: nil, now: now) == .waiting)
        #expect(PetMood(agent: .idle, reported: nil, until: nil, now: now) == .idle)
        // A beat shows until its end, then the pet rests, even with an error still on the status.
        #expect(PetMood(agent: .idle, reported: .happy, until: now + 5, now: now) == .happy)
        #expect(PetMood(agent: .error, reported: .confused, until: now + 5, now: now) == .confused)
        #expect(PetMood(agent: .error, reported: .confused, until: now - 1, now: now) == .idle)
        // A beat without an end (a v2 server's lasting "happy") is not one.
        #expect(PetMood(agent: .idle, reported: .happy, until: nil, now: now) == .idle)
        #expect(PetMood.allCases.map(\.animation) == [.idle, .running, .waiting, .jumping, .failed])
    }

    @Test func moodDecodesOldSnapshots() throws {
        let old = #"{"petName":"Pip","petLevel":6,"levelProgress":0.6,"hunger":0.35,"energy":0.7,"happiness":0.82,"asleep":false,"mood":"content","agentStatus":"idle","updatedAt":0}"#
        let snap = try JSONDecoder().decode(SharedSnapshot.self, from: Data(old.utf8))
        #expect(snap.petName == "Pip" && snap.mood == .idle)
    }

    @Test func manifestReadsCodexPetJSON() throws {
        let json = #"{"id":"two-tabby-cats","displayName":"Two Tabby Cats","description":"A Codex pet.","spritesheetPath":"spritesheet.webp"}"#
        let m = try JSONDecoder().decode(PetManifest.self, from: Data(json.utf8))
        #expect(m.displayName == "Two Tabby Cats")
        #expect(m.layout == .codex)
    }
}

@Suite("live activity")
struct ActivityTests {
    @Test func questionKeepsFourButtonsAndDropsOther() {
        let q = PendingQuestion(id: "c", kind: .clarify, text: "Which?", options: [
            QuestionOption(id: "a", label: "A"), QuestionOption(id: "b", label: "B"),
            QuestionOption(id: "c", label: "C"), QuestionOption(id: "d", label: "D"),
            QuestionOption(id: "e", label: "E"), QuestionOption(id: "other", label: "Other…"),
        ])
        let aq = ActivityQuestion(q)
        #expect(aq.options.map(\.id) == ["a", "b", "c", "d"])
        #expect(aq.detail == nil)
        let approval = ActivityQuestion(Fixtures.approvalQuestion(messageID: 1))
        #expect(approval.title.hasPrefix("Hermes wants to delete the backup snapshots"))
        #expect(approval.options.last?.destructive == true)
    }
}

@Suite("localization")
struct LocalizationTests {
    /// HermesCore's strings come from its own catalog, French included (not the app's bundle).
    @Test func coreShipsFrench() throws {
        let core = Bundle(for: HermesStore.self)
        let path = try #require(core.path(forResource: "fr", ofType: "lproj"))
        let fr = try #require(Bundle(path: path))
        #expect(fr.localizedString(forKey: "Idle", value: nil, table: nil) == "Au repos")
        #expect(fr.localizedString(forKey: "Needs you", value: nil, table: nil) == "A besoin de toi")
        #expect(fr.localizedString(forKey: "End sub-chat", value: nil, table: nil) == "Terminer la sous-discussion")
        #expect(fr.localizedString(forKey: "Upload failed: %@", value: nil, table: nil) == "Échec de l’envoi\u{a0}: %@")
        // In the test's (English) locale, the development language.
        #expect(AgentStatus.waitingUser.label == "Needs you")
    }
}
