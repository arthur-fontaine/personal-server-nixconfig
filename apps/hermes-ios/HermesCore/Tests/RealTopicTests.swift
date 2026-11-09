import Foundation
import Testing
@testable import HermesCore

/// The App topic's real slots (`RealSnapshot`, protocol v4), as TDLib hands them to the app: the
/// JSON as a message's plain text with a `pre` entity (the server sends `<pre><code class="language-json">`).
@MainActor
@Suite("The App topic's real v4 slots")
struct RealTopicTests {
    static func message(_ botAPIID: Int64, _ json: String, edited: Bool = false) -> ChatMessage {
        var m = Fixtures.appMessage(id: botAPIID, json: json)
        if edited { m.editDate = .now }
        return m
    }

    @Test func eachSlotDecodes() throws {
        guard case .state(let s)? = AppProtocol.decode(RealSnapshot.state) else { Issue.record("state"); return }
        #expect(s.agent?.status == .working)
        #expect(s.agent?.chat == .main)
        #expect(s.agent?.task?.hasPrefix("terminal:") == true)
        #expect(s.pet?.id == "juste-un")
        #expect(s.pet?.spriteMessageID == 1341)
        #expect(s.slots["controls"] == 675)
        #expect(s.questions.isEmpty && s.pending.isEmpty)

        guard case .controls(let c)? = AppProtocol.decode(RealSnapshot.controls) else { Issue.record("controls"); return }
        #expect(c.commands.count == 19)
        #expect(c.permissionMode?.value == "auto")
        #expect(c.model?.chain.count == 4)
        #expect(c.model?.last[.main]?.model == "deepseek-v4.1-flash")
        #expect(c.presets.count == 4)
        #expect(!c.commands(for: CommandContext(topic: .main)).isEmpty)

        guard case .devices(let d)? = AppProtocol.decode(RealSnapshot.devices) else { Issue.record("devices"); return }
        #expect(d.devices.count == 4)
        #expect(d.teamPaid == false)

        guard case .stats(let st)? = AppProtocol.decode(RealSnapshot.stats) else { Issue.record("stats"); return }
        #expect(st.models.count == 5)
        #expect(st.machine?.cpuHistory.count == 12)
    }

    func store() -> HermesStore {
        let store = HermesStore(client: FakeTelegramClient(startsLoggedIn: false), config: .preview)
        store._setBot(FakeTelegramClient.botChat, appTopic: FakeTelegramClient.appTopic)
        return store
    }

    @Test func theStoreAppliesEachSlotReplayedAndLive() {
        let store = store()
        // Launch: history, newest first, replayed oldest first.
        for (id, json) in [(RealSnapshot.statsID, RealSnapshot.stats), (RealSnapshot.devicesID, RealSnapshot.devices),
                           (RealSnapshot.controlsID, RealSnapshot.controls), (RealSnapshot.stateID, RealSnapshot.state)] {
            store.handleAppMessage(Self.message(id, json), replay: true)
        }
        #expect(store.controls.commands.count == 19)
        #expect(store.agent.status == .working)
        #expect(store.pet?.name == "Juste Un")
        #expect(store.delivery.devices.count == 4)
        #expect(store.stats?.models.count == 5)

        // Live: the same slot message edited in place (its id never changes).
        let idle = RealSnapshot.state.replacingOccurrences(of: #""status":"working""#, with: #""status":"idle""#)
        store._apply(.messageChanged(FakeTelegramClient.botChat.chatID, Self.message(RealSnapshot.stateID, idle, edited: true)))
        #expect(store.agent.status == .idle)
    }
}

@MainActor
@Suite("The App topic, tolerant and resynced")
struct TopicResyncTests {
    @Test func aNewerVersionAndABadFieldKeepTheRest() {
        let text = RealSnapshot.state.replacingOccurrences(of: #""v":4"#, with: #""v":9"#)
            .replacingOccurrences(of: #""subchats":[]"#, with: #""subchats":"oops""#)
        guard case .success(let d) = AppProtocol.decodeResult(text), case .state(let s) = d.payload else { Issue.record("state"); return }
        #expect(d.version == 9)
        #expect(s.agent?.status == .working)
        #expect(s.pet?.name == "Juste Un")
        #expect(AppProtocol.decodeResult("hello") .failureValue == .notJSON)
        #expect(AppProtocol.decodeResult("{\"v\":4}").failureValue == .noType)
    }

    /// A clarify as the server now writes it: the card shows, the Telegram copy (keyboard message,
    /// Bot API id 1500 = TDLib 1500 << 20) is the question's message.
    @Test func aV4ClarifyBecomesACard() {
        let store = HermesStore(client: FakeTelegramClient(startsLoggedIn: false), config: .preview)
        store._setBot(FakeTelegramClient.botChat, appTopic: FakeTelegramClient.appTopic)
        let question = #""questions":[{"id":"cl:abc","kind":"clarify","chat":0,"message_id":1500,"text":"Which hotel?","summary":null,"detail":null,"spoken":"Which hotel?","command":null,"options":[{"id":"0","label":"Casa","data_b64":"Y2w6YWJjOjA="},{"id":"other","label":"✏️ Other","data_b64":"Y2w6YWJjOm90aGVy"}],"asked_at":"2026-11-09T10:40:00Z"}]"#
        let json = RealSnapshot.state.replacingOccurrences(of: #""questions":[]"#, with: question)
            .replacingOccurrences(of: #""status":"working""#, with: #""status":"waiting_user""#)
        store._apply(.messageChanged(FakeTelegramClient.botChat.chatID, RealTopicTests.message(RealSnapshot.stateID, json, edited: true)))
        #expect(store.questions(in: .main).count == 1)
        #expect(store.question(forMessage: BotAPIID.tdlib(1500))?.options.first?.label == "Casa")
        #expect(store.agent.status == .waitingUser)
        #expect(store.topicLog.slots["state"]?.messageID == RealSnapshot.stateID)
    }

    /// The slots read by id (launch, reconnect, every 30 s), not only through history and edits.
    @Test func slotsAreReadByTheirIDs() async throws {
        let client = FakeTelegramClient()
        let store = HermesStore(client: client, config: .preview)
        store.slotMemory = SlotMemory(defaults: nil)
        store.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while store.controls.commands.isEmpty || store.stats == nil {
            guard ContinuousClock.now < deadline else { Issue.record("no slots"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.resyncAppTopic()
        #expect(store.topicLog.lastError == nil)
        #expect(store.topicLog.slots.keys.sorted() == ["controls", "devices", "state", "stats"])
    }

    /// The bug on Arthur's iPhone (build 202611091159): the slots sit under 100+ newer App-topic
    /// messages, history never reaches them, no slot id is remembered yet, and the state never
    /// arrives ("never decoded"). Hello's reply names them, and the app reads them by id.
    @Test func slotsBuriedInHistoryArriveThroughHello() async throws {
        let client = FakeTelegramClient(startsLoggedIn: true)
        client.streamDelay = .milliseconds(1)
        client.slotsBuried = true
        let store = HermesStore(client: client, config: .preview)
        store.slotMemory = SlotMemory(defaults: nil)
        store.start()
        let deadline = ContinuousClock.now + .seconds(8)
        while store.controls.commands.isEmpty || store.stats == nil {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.controls.commands.isEmpty)
        #expect(store.stats != nil)
        #expect(store.state.agent != nil)
    }
}

extension Result {
    var failureValue: Failure? { if case .failure(let f) = self { f } else { nil } }

}
