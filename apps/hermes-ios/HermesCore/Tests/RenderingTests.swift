import Foundation
import Testing
@testable import HermesCore

@Suite("message segments")
struct SegmentTests {
    @Test func splitsParagraphsAndCodeBlocks() {
        let text = "Intro **bold**\n\nSecond `x`\n```swift\nlet a = 1\n```\nAfter"
        let f = Markdownish.parse(text)
        let segs = MessageSegments.make(f)
        #expect(segs.count == 4)
        guard case .text(let first) = segs[0], case .code(let code, let lang) = segs[2], case .text(let last) = segs[3] else {
            Issue.record("bad segments \(segs)"); return
        }
        #expect(String(first.characters) == "Intro bold")
        #expect(first.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(code == "let a = 1" && lang == "swift")
        #expect(String(last.characters) == "After")
    }

    @Test func entityOffsetsAreUTF16() {
        // "🔥" is two UTF-16 units: the bold must land on "hot", not shift.
        let f = FormattedText("🔥 hot", entities: [TextEntity(offset: 3, length: 3, kind: .bold)])
        guard case .text(let a)? = MessageSegments.make(f).first else { Issue.record("no text"); return }
        let bold = a.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(a[$0.range].characters) }
        #expect(bold == ["hot"])
    }

    @Test func linksAndOutOfRangeEntities() {
        let f = FormattedText("see example.com now", entities: [
            TextEntity(offset: 4, length: 11, kind: .url), TextEntity(offset: 50, length: 3, kind: .bold),
        ])
        guard case .text(let a)? = MessageSegments.make(f).first else { Issue.record("no text"); return }
        #expect(a.runs.compactMap(\.link).first == URL(string: "https://example.com"))
    }

    @Test func fileMarkersAreHiddenButEntitiesKept() {
        let f = FormattedText("Look **here**\n[fichier: https://gofile.io/d/x]", entities: [TextEntity(offset: 5, length: 4, kind: .bold)])
        let segs = MessageSegments.make(f)
        #expect(segs.count == 1)
        guard case .text(let a) = segs[0] else { return }
        #expect(!String(a.characters).contains("fichier"))
    }

    @Test func blockquotesBecomeQuotes() {
        let f = FormattedText("a\nquoted\nb", entities: [TextEntity(offset: 2, length: 6, kind: .blockquote)])
        let segs = MessageSegments.make(f)
        #expect(segs.count == 3)
        if case .quote(let q) = segs[1] { #expect(String(q.characters) == "quoted") } else { Issue.record("no quote") }
    }
}

@Suite("stream smoother")
struct SmootherTests {
    @Test func catchesUpWithinAFewFrames() {
        var s = StreamSmoother()
        s.update(String(repeating: "a", count: 80))
        var frames = 0
        while s.tick() { frames += 1 }
        #expect(frames <= 30)
        #expect(s.isCaughtUp && s.shown.count == 80)
    }

    @Test func appendsContinueAndRewritesRestart() {
        var s = StreamSmoother()
        s.update("Hello")
        s.finish()
        s.update("Hello world")
        #expect(s.shown == "Hello")
        s.tick()
        #expect(s.shown.count > 5)
        s.update("Bye")
        #expect(s.shown == "")
        s.finish()
        #expect(s.shown == "Bye")
    }
}
