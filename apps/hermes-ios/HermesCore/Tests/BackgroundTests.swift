import Foundation
import Testing
@testable import HermesCore

/// Brief item 9: when a free-team app stays running in the background, and notifications once each.
@Suite("Background on a free team")
struct BackgroundTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func staysAliveOnlyWhileItMatters() {
        #expect(KeepAlivePolicy.stayAlive(agent: .working, questions: 0, call: false, lastActivity: nil, now: now))
        #expect(KeepAlivePolicy.stayAlive(agent: .idle, questions: 1, call: false, lastActivity: nil, now: now))
        #expect(KeepAlivePolicy.stayAlive(agent: .idle, questions: 0, call: true, lastActivity: nil, now: now))
        #expect(KeepAlivePolicy.stayAlive(agent: .idle, questions: 0, call: false, lastActivity: now.addingTimeInterval(-9 * 60), now: now))
        #expect(!KeepAlivePolicy.stayAlive(agent: .idle, questions: 0, call: false, lastActivity: now.addingTimeInterval(-11 * 60), now: now))
        #expect(!KeepAlivePolicy.stayAlive(agent: .idle, questions: 0, call: false, lastActivity: nil, now: now))
        #expect(!KeepAlivePolicy.stayAlive(agent: .error, questions: 0, call: false, lastActivity: now.addingTimeInterval(-60), now: now, grace: 30))
    }

    @Test func aNotificationIsPostedOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "posted-test-\(UUID())"))
        let posted = PostedNotifications(defaults: defaults)
        #expect(posted.claim("0-5003-message"))
        #expect(!posted.claim("0-5003-message"))
        #expect(!PostedNotifications(defaults: defaults).claim("0-5003-message"), "across launches")
    }

    @MainActor @Test func aRelaunchPostsRecentNotifiesOnly() async throws {
        let (store, _) = try await StoreTests().makeStore()
        var received: [String] = []
        store.hooks.notify = { received.append($0.body) }
        let recent = Fixtures.appMessage(id: 960, json: #"{"v":4,"type":"notify","chat":0,"message_id":5,"body":"Recent"}"#)
        var old = Fixtures.appMessage(id: 961, json: #"{"v":4,"type":"notify","chat":0,"message_id":6,"body":"Old"}"#)
        old.date = .now.addingTimeInterval(-2 * 60 * 60)
        store.handleAppMessage(recent, replay: true)
        store.handleAppMessage(old, replay: true)
        #expect(received == ["Recent"])
    }

    @MainActor @Test func hermesActivityOpensTheWindow() async throws {
        let (store, _) = try await StoreTests().makeStore()
        let before = store.lastBotActivity
        store._apply(.newMessage(FakeTelegramClient.botChat.chatID, ChatMessage(id: Fixtures.id(1500), topic: .main, date: .now,
                                                                                isOutgoing: false, text: FormattedText("Done."))))
        #expect(store.lastBotActivity != nil && store.lastBotActivity != before)
    }
}
