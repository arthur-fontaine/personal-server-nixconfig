import Foundation
import Testing
@testable import HermesCore

/// design-rules 16: replies show who wrote the original and its first line; sending replies.
@MainActor
@Suite("Replies")
struct ReplyTests {
    let store = StoreTests()

    @Test func excerptIsTheFirstLineOfText() {
        func msg(_ text: String, file: FileAttachment? = nil) -> ChatMessage {
            ChatMessage(id: 1, topic: .main, date: .now, isOutgoing: false, text: FormattedText(text), attachment: file)
        }
        #expect(ReplyPreview.excerpt(of: msg("First line\nsecond line")) == "First line")
        #expect(ReplyPreview.excerpt(of: msg("\n  \n```\nls -la\n```")) == "ls -la")
        #expect(ReplyPreview.excerpt(of: msg("", file: FileAttachment(kind: .document, fileID: 1, name: "Statements.pdf", size: 1_400_000))) == "Statements.pdf")
    }

    @Test func fixturesReplyInBothDirections() async throws {
        let (store, _) = try await store.makeStore()
        let main = store.messages(in: .main)
        let yes = try #require(main.first { $0.id == 1004 })
        #expect(store.replyPreview(for: yes) == ReplyPreview(originalID: 1003, content: .message(
            author: .hermes, excerpt: "The external disk was full, so restic stopped before pruning:")))
        let done = try #require(main.first { $0.id == 1010 })
        #expect(store.replyPreview(for: done)?.content == .message(author: .you, excerpt: "Remind me to call mum tonight"))
        #expect(store.replyPreview(for: try #require(main.first { $0.id == 1002 })) == nil)
    }

    @Test func aDeletedOriginalReadsAsDeleted() async throws {
        let (store, _) = try await store.makeStore()
        await store.loadHistory(12)
        let merged = try #require(store.messages(in: 12).first { $0.id == 2003 })
        #expect(store.replyPreview(for: merged)?.content == .loading)
        try await self.store.waitUntil { store.replyPreview(for: merged)?.content == .deleted }
        #expect(await store.loadAround(1999, in: 12) == false)
    }

    @Test func anOriginalElsewhereIsFetched() async throws {
        let (store, _) = try await store.makeStore()
        // A reply whose original isn't in this topic's loaded history: fetched by id.
        let stray = ChatMessage(id: 9001, topic: 57, date: .now, isOutgoing: true, text: FormattedText("Same as this"), replyTo: 1009)
        try await self.store.waitUntil { store.replyPreview(for: stray)?.content == .message(author: .you, excerpt: "Remind me to call mum tonight") }
        #expect(await store.loadAround(1001, in: .main))
    }

    @Test func reachingAnOriginalPagesBack() async throws {
        let (store, _) = try await store.makeStore()
        await store.loadHistory(57)
        #expect(!store.messages(in: 57).contains { $0.id == 5001 }, "the first save is beyond the first page")
        #expect(await store.loadAround(5001, in: 57))
        let ids = store.messages(in: 57).map(\.id)
        #expect(ids.first == 5001 && ids == ids.sorted() && Set(ids).count == ids.count, "loaded without a gap or a duplicate")
    }

    @Test func sendingAReplyPassesItsOriginal() async throws {
        let (store, client) = try await store.makeStore()
        try await store.send("And the photos?", in: .main, replyTo: 1003)
        #expect(client.repliedTo == [1003])
        #expect(store.messages(in: .main).last?.replyTo == 1003)
    }
}
