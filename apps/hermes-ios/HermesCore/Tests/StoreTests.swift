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
        #expect(store.petMood == .sad)
    }

    @Test func answeringPressesTheButtonData() async throws {
        let (store, client) = try await makeStore()
        let q = try #require(store.questions.first)
        _ = try await store.answer(q, with: q.options[0])
        #expect(store.questions.isEmpty)
        try await waitUntil { store.messages(in: .main).first { $0.id == 1005 }?.buttons.isEmpty == true }
        _ = client
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
        // …and the notify message is acked so the bot deletes it.
        try await waitUntil { client.sent.contains { $0.contains("\"ack\"") && $0.contains("950") } }
    }

    @Test func petActionIsOptimisticThenConfirmedByAReply() async throws {
        let (store, client) = try await makeStore()
        let hunger = try #require(store.pet?.hunger)
        try await store.perform(.feed)
        #expect(client.sent.contains { $0.contains("pet.feed") })
        try await waitUntil { (store.pet?.hunger ?? 1) < hunger }
    }

    @Test func callStartReturnsATicket() async throws {
        let (store, _) = try await makeStore()
        let ticket = try await store.requestCall()
        #expect(ticket.token == "demo")
        #expect(ticket.candidates.first?.scheme == "ws")
    }

    @Test func createAndUnlockSubchatsSendCommands() async throws {
        let (store, client) = try await makeStore()
        try await store.createSubchat(name: "Taxes", preset: "secret")
        #expect(client.sent.contains("/sub new secret Taxes"))
        try await store.unlockSubchat(31, passphrase: "pw")
        #expect(client.sent.contains("/sub unlock pw"))
        #expect(!store.messages(in: 31).contains { $0.text.text.hasPrefix("/sub unlock") })
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

    @Test func moodFollowsAgentThenNeeds() {
        let pet = PetState(id: "p", name: "P", hunger: 0.2, energy: 0.8, happiness: 0.9)
        #expect(PetMood(agent: .working, pet: pet) == .busy)
        #expect(PetMood(agent: .thinking, pet: pet).animation == .review)
        #expect(PetMood(agent: .waitingUser, pet: pet).animation == .waiting)
        #expect(PetMood(agent: .idle, pet: pet) == .happy)
        var hungry = pet; hungry.hunger = 0.9
        #expect(PetMood(agent: .idle, pet: hungry) == .hungry)
        var asleep = pet; asleep.asleep = true
        #expect(PetMood(agent: .working, pet: asleep) == .asleep)
    }

    @Test func levelProgressUsesTheProtocolCurve() {
        // Level n needs 100·n·(n+1)/2: level 6 spans 1500…2100.
        #expect(PetState.totalXP(forLevel: 5) == 1500)
        let pet = PetState(id: "p", name: "P", xp: 1800, level: 6, xpForNextLevel: 2100)
        #expect(abs(pet.levelProgress - 0.5) < 0.001)
    }

    @Test func actionsAreOfferedByState() {
        var pet = PetState(id: "p", name: "P")
        #expect(PetAction.available(for: pet) == [.feed, .play, .sleep])
        pet.asleep = true
        #expect(PetAction.available(for: pet) == [.feed, .wake])
        #expect(PetAction.wake.optimisticallyApplied(to: pet).asleep == false)
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
        #expect(approval.title.hasPrefix("Delete backup snapshots"))
        #expect(approval.options.last?.destructive == true)
    }
}
