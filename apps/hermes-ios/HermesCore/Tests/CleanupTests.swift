import Foundation
import Testing
@testable import HermesCore

/// Arthur's first real use: no 🔊 line, the 📎 details marker, questions without their repeated
/// choices, steered messages shown as waiting bubbles (brief items 4, 7, 10).
@Suite("What the app shows of Hermes' text")
struct CleanupTests {
    @Test func aSpokenLineIsNeverShown() {
        let t = FormattedText("The build passed.\n\n🔊 The build passed.", entities: [TextEntity(offset: 10, length: 6, kind: .bold)])
        let (shown, details) = MessageCleanup.shown(t)
        #expect(shown.text == "The build passed.")
        #expect(shown.entities == [TextEntity(offset: 10, length: 6, kind: .bold)])
        #expect(!details)
        #expect(MessageCleanup.shown(FormattedText("🔊 Only this")).text.text.isEmpty)
    }

    @Test func aSpokenLineInTheMiddleMovesLaterEntities() {
        let t = FormattedText("A\n🔊 x\nB code", entities: [TextEntity(offset: 9, length: 4, kind: .code)])
        let shown = MessageCleanup.shown(t).text
        #expect(shown.text == "A\nB code")
        #expect(shown.entities == [TextEntity(offset: 4, length: 4, kind: .code)])
    }

    @Test func theDetailsMarkerIsStrippedAndRemembered() {
        let t = FormattedText("📎 Links: https://example.com", entities: [TextEntity(offset: 10, length: 19, kind: .url)])
        let (shown, details) = MessageCleanup.shown(t)
        #expect(details)
        #expect(shown.text == "Links: https://example.com")
        #expect(shown.entities == [TextEntity(offset: 7, length: 19, kind: .url)])
    }

    @Test func aCallSpeaksOnlyWhatPrecedesTheDetails() {
        #expect(MessageCleanup.speakable("It's sunny.\n🔊 It's sunny.") == "It's sunny.")
        #expect(MessageCleanup.speakable("It's sunny.\n📎 Forecast: …") == "It's sunny.")
        #expect(MessageCleanup.speakable("📎 Forecast: …") == "")
    }

    @Test func aClarifyDropsItsChoicesAndTheSkipHint() {
        let q = PendingQuestion(id: "cl:1", kind: .clarify, text: """
            ❓ Which hotel should I hold?

            1. Casa do Largo
            2. Alfama Patio
            Reply "skip" to skip this question.
            """, options: [QuestionOption(id: "0", label: "1"), QuestionOption(id: "1", label: "Alfama Patio"),
                           QuestionOption(id: "other", label: "✏️ Other (type answer)")])
        let shown = QuestionText.display(q)
        #expect(shown.text == "Which hotel should I hold?")
        #expect(shown.options.map(\.label) == ["Casa do Largo", "Alfama Patio", "✏️ Other (type answer)"])
    }

    @Test func aListThatIsNotTheChoicesStays() {
        let q = PendingQuestion(id: "cl:2", kind: .clarify, text: "Plan:\n1. Build\n2. Deploy\nGo ahead?\nRépondez « skip » pour passer cette question.",
                                options: [QuestionOption(id: "0", label: "Yes"), QuestionOption(id: "1", label: "No")])
        #expect(QuestionText.display(q).text == "Plan:\n1. Build\n2. Deploy\nGo ahead?")
    }

    @Test func pendingTurnsDecode() throws {
        let json = #"{"v":4,"type":"state","pending":[{"chat":0,"message_id":1301,"since":"2026-11-09T10:00:00Z"},{"chat":12}]}"#
        guard case .state(let s)? = AppProtocol.decode(json) else { Issue.record("no state"); return }
        #expect(s.pending == [PendingTurn(chat: .main, messageID: 1301, since: ISO8601DateFormatter().date(from: "2026-11-09T10:00:00Z"))])
    }

    @MainActor @Test func aSteeredMessageWaitsAndTheNoticeIsHidden() async throws {
        let tests = StoreTests()
        let (store, _) = try await tests.makeStore()
        let chat = FakeTelegramClient.botChat.chatID
        let mine = ChatMessage(id: Fixtures.id(1301), topic: .main, date: .now, isOutgoing: true, text: FormattedText("Also check the logs"))
        store._apply(.newMessage(chat, mine))
        store._apply(.newMessage(chat, ChatMessage(id: Fixtures.id(1302), topic: .main, date: .now, isOutgoing: false,
                                                   text: FormattedText("⏩ Steered into current run. Your message arrives after the next tool call."))))
        #expect(!store.messages(in: .main).contains { $0.id == Fixtures.id(1302) })
        store._apply(.messageChanged(chat, Fixtures.appMessage(id: 910, json: #"{"v":4,"type":"state","agent":{"status":"working"},"pending":[{"chat":0,"message_id":1301}]}"#)))
        #expect(store.isWaiting(try #require(store.messages(in: .main).last)))
        store._apply(.messageChanged(chat, Fixtures.appMessage(id: 910, json: #"{"v":4,"type":"state","agent":{"status":"working"},"pending":[]}"#)))
        #expect(!store.isWaiting(try #require(store.messages(in: .main).last)))
    }

    @MainActor @Test func hermesMessagesArriveCleaned() async throws {
        let (store, _) = try await StoreTests().makeStore()
        let chat = FakeTelegramClient.botChat.chatID
        store._apply(.newMessage(chat, ChatMessage(id: Fixtures.id(1401), topic: .main, date: .now, isOutgoing: false,
                                                   text: FormattedText("Done.\n🔊 Done."))))
        store._apply(.newMessage(chat, ChatMessage(id: Fixtures.id(1402), topic: .main, date: .now, isOutgoing: false,
                                                   text: FormattedText("📎 The log: https://x.y"))))
        let last = store.messages(in: .main).suffix(2)
        #expect(last.map(\.text.text) == ["Done.", "The log: https://x.y"])
        #expect(last.map(\.isCallDetails) == [false, true])
    }
}
