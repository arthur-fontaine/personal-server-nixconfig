import Foundation
import Testing
@testable import HermesCore

@MainActor
@Suite("Hermes' memory (protocol §4.1)")
struct MemoryTests {
    func makeStore() async throws -> (HermesStore, FakeTelegramClient) {
        let client = FakeTelegramClient()
        client.streamDelay = .milliseconds(1)
        let store = HermesStore(client: client, config: .preview)
        store.start()
        try await waitUntil { store.isReady && store.appTopicID != nil && store.state.pet != nil }
        return (store, client)
    }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func requests(_ client: FakeTelegramClient) -> [String] {
        client.sent.filter { $0.contains(#""type":"memory."#) }
    }

    @Test func decodesTheServersReplies() throws {
        let volumes = try MemoryReply.volumes(reply(#"""
        {"volumes":[{"chat":0,"name":"Main chat","volume":"main","messages":3712,"locked":false,"private":false},
                    {"chat":455,"name":null,"volume":"chat-1","messages":null,"locked":true,"private":true},
                    {"name":"no chat"}]}
        """#))
        #expect(volumes == [MemoryVolume(chat: .main, name: "Main chat", volume: "main", messages: 3712),
                            MemoryVolume(chat: 455, volume: "chat-1", messages: nil, locked: true, isPrivate: true)])

        let page = try MemoryReply.page(reply(#"""
        {"lines":[{"first":0,"n":2048,"text":"Set up","built":true},{"first":3711,"n":1,"text":null,"built":false}],
         "truncated":true,"next":3712}
        """#))
        #expect(page.lines == [MemoryLine(first: 0, n: 2048, text: "Set up"), MemoryLine(first: 3711, n: 1, text: nil)])
        #expect(page.next == 3712 && page.lines[0].last == 2047 && page.lines[1].isMessage && !page.lines[1].built)
        #expect(try MemoryReply.page(reply(#"{"lines":[]}"#)).next == nil)

        let message = try MemoryReply.message(reply(#"""
        {"message":{"i":3712,"kind":"hermes","date":"2026-11-11T09:30:00+00:00","text":"Done…","cut":true}}
        """#))
        #expect(message.index == 3712 && message.kind == .hermes && message.isCut)
        #expect(message.date == Date(timeIntervalSince1970: 1_794_389_400))
        #expect(try MemoryReply.message(reply(#"{"message":{"i":1,"kind":"later","text":"x"}}"#)).kind == nil)
    }

    @Test func errorsMapToTheirCase() {
        func error(_ code: String) -> MemoryError? {
            let r = ReplyPayload(fields: ["ok": .bool(false), "error": .object(["code": .string(code), "message": .string("m")])])
            do { _ = try MemoryReply.page(r); return nil } catch { return error as? MemoryError }
        }
        #expect(error("locked") == .locked)
        #expect(error("not_found") == .notFound)
        #expect(error("unknown_type") == .unavailable)
        #expect(error("failed") == .failed("m"))
    }

    @Test func requestsAreWhatTheServerReads() throws {
        func fields(_ r: AppRequest) throws -> [String: JSONValue] {
            try JSONDecoder().decode([String: JSONValue].self, from: try #require(AppProtocol.extractJSON(from: AppProtocol.encode(r))))
        }
        #expect(try fields(.memoryVolumes)["type"] == .string("memory.volumes"))
        let view = try fields(.memoryView(chat: 31, after: 3584))
        #expect(view["type"] == .string("memory.lines") && view["chat"] == .number(31) && view["after"] == .number(3584))
        #expect(try fields(.memoryView(chat: .main))["after"] == nil)
        let line = try fields(.memoryLine(chat: 0, first: 2048, n: 1024))
        #expect(line["first"] == .number(2048) && line["n"] == .number(1024))
    }

    @Test func listsTheVolumes() async throws {
        let (store, _) = try await makeStore()
        let volumes = try await store.memoryVolumes()
        #expect(volumes.map(\.chat) == [.main, 12, 44, 31])
        #expect(volumes[0].messages == 3670 && !volumes[0].isPrivate)
        let taxes = try #require(volumes.last)
        #expect(taxes.isPrivate && taxes.locked && taxes.messages == nil)
    }

    @Test func readsTheViewInPagesThenDrillsDownToAMessage() async throws {
        let (store, client) = try await makeStore()
        let first = try await store.memoryView(chat: .main)
        #expect(first.lines.map(\.id) == ["0+2048", "2048+1024", "3072+512", "3584+64", "3648+16"])
        let next = try #require(first.next)
        let rest = try await store.memoryView(chat: .main, after: next)
        #expect(rest.next == nil)
        #expect(rest.lines.map(\.id) == ["3664+4", "3668+1", "3669+1"])
        #expect(rest.lines.last?.built == false && rest.lines.last?.text == nil)

        let halves = try await store.memoryHalves(chat: .main, of: first.lines[1])
        #expect(halves.map(\.id) == ["2048+512", "2560+512"] && halves.allSatisfy(\.built))
        let message = try await store.memoryMessage(chat: .main, index: 3668)
        #expect(message.kind == .user && message.text.contains("prune") && message.date != nil)

        // Read again: from the session's cache, no new request.
        let sent = requests(client).count
        #expect(try await store.memoryHalves(chat: .main, of: first.lines[1]) == halves)
        #expect(try await store.memoryMessage(chat: .main, index: 3668) == message)
        #expect(requests(client).count == sent)
        #expect(store.memoryCache.count == 2)
        // The view moves with every turn: never cached.
        _ = try await store.memoryView(chat: .main)
        #expect(requests(client).count == sent + 1)
    }

    @Test func halvesWaitingForTheirSummaryAreAskedAgain() async throws {
        let (store, client) = try await makeStore()
        // 3668+2 holds the newest message, not summarized yet.
        let halves = try await store.memoryHalves(chat: .main, of: MemoryLine(first: 3668, n: 2, text: nil))
        #expect(halves.map(\.built) == [true, false])
        let sent = requests(client).count
        _ = try await store.memoryHalves(chat: .main, of: MemoryLine(first: 3668, n: 2, text: nil))
        #expect(requests(client).count == sent + 1)
        #expect(store.memoryCache.count == 0)
    }

    @Test func aLockedMemoryReadsOnceItsChatIsUnlocked() async throws {
        let (store, _) = try await makeStore()
        await #expect(throws: MemoryError.locked) { try await store.memoryView(chat: 31) }
        await #expect(throws: MemoryError.locked) { try await store.memoryMessage(chat: 31, index: 0) }
        await #expect(throws: MemoryError.notFound) { try await store.memoryView(chat: 999) }

        try await store.unlockSubchat(31, passphrase: "correct horse")
        try await waitUntil { store.subchat(31)?.unlocked == true }
        let taxes = try #require(try await store.memoryVolumes().first { $0.chat == 31 })
        #expect(!taxes.locked && taxes.isPrivate && taxes.messages == 40)
        let view = try await store.memoryView(chat: 31)
        #expect(view.lines.first?.text?.contains("2026 return") == true)
        _ = try await store.memoryMessage(chat: 31, index: 0)
        #expect(store.memoryCache.count == 1)
        store.forgetMemory(chat: 31)
        #expect(store.memoryCache.count == 0)
    }

    @Test func aBadLineIsRefused() async throws {
        let (store, _) = try await makeStore()
        await #expect(throws: MemoryError.self) { try await store.memoryHalves(chat: .main, of: MemoryLine(first: 1, n: 2, text: nil)) }
        await #expect(throws: MemoryError.notFound) { try await store.memoryMessage(chat: .main, index: 9999) }
    }

    private func reply(_ data: String) -> ReplyPayload {
        let json = #"{"v":4,"type":"reply","re":1,"ok":true,"data":\#(data)}"#
        let fields = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))) ?? [:]
        return ReplyPayload(fields: fields)
    }
}
