import Foundation
import Testing
@testable import HermesCore

/// Nov 12 on Arthur's iPhone: Settings › Memory always timed out. The server answered, but with
/// `re` = the bot's id of the request, which the owner's client numbers differently: no reply ever
/// matched. Requests now carry the app's own `rid`, echoed back.
@MainActor
@Suite("Request ids")
struct RequestIDTests {
    @Test func aReplyFindsItsRequestByRidWhateverTheIDs() async throws {
        let client = FakeTelegramClient()
        client.streamDelay = .milliseconds(1)
        let store = HermesStore(client: client, config: .preview)
        store.uiMemory = UISpecMemory(directory: nil)
        store.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while !(store.isReady && store.state.pet != nil), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let reply = try await store.sendRequest(.memoryVolumes, timeout: .seconds(5))
        #expect(reply?.ok == true && reply?.rid != nil)
        // The request (an ack of the reply may follow it) carries that rid.
        let rid = try #require(reply?.rid)
        #expect(client.sent.contains { $0.contains("memory.volumes") && $0.contains(#""rid":"\#(rid)""#) })
    }
}
