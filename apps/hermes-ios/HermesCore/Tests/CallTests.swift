import Foundation
import Testing
@testable import HermesCore

@Suite("speech chunker")
struct SpeechChunkerTests {
    @Test func speaksSentencesAsTheyComplete() {
        var c = SpeechChunker()
        #expect(c.feed("Sure, I checked").isEmpty)
        #expect(c.feed("Sure, I checked the backup. It") == ["Sure, I checked the backup."])
        #expect(c.feed("Sure, I checked the backup. It freed 212 GB. Anything") == ["It freed 212 GB."])
        #expect(c.feed("Sure, I checked the backup. It freed 212 GB. Anything else?", final: true) == ["Anything else?"])
    }

    @Test func decimalsAndAbbreviationsDontSplit() {
        var c = SpeechChunker()
        #expect(c.feed("CPU is at 12.5 percent").isEmpty)
        #expect(c.feed("CPU is at 12.5 percent and RAM 50.", final: true) == ["CPU is at 12.5 percent and RAM 50."])
    }

    @Test func codeBlocksAreMentionedNotRead() {
        var c = SpeechChunker()
        let a = c.feed("Here it is:\n```\nrm -rf /tmp/x\n")
        #expect(a == ["Here it is:"])
        let b = c.feed("Here it is:\n```\nrm -rf /tmp/x\n```\nDone.", final: true)
        #expect(b == ["a code block Done."] || b == ["a code block", "Done."] || b.joined(separator: " ").contains("code block"))
        #expect(!b.joined().contains("rm -rf"))
    }

    @Test func markdownLinksAndEmojiAreCleaned() {
        #expect(SpeechChunker.speakable("**Done** ✅ see [the doc](https://x.y/z) or https://example.com/a/b") == "Done see the doc or a link to example.com")
        #expect(SpeechChunker.speakable("- first item") == "first item")
        #expect(SpeechChunker.speakable("Big file\n[fichier: https://gofile.io/d/x]") == "Big file a file")
    }

    @Test func rewritesAreNotSpokenTwice() {
        var c = SpeechChunker()
        #expect(c.feed("One. Two") == ["One."])
        // The draft got rewritten after what was spoken.
        #expect(c.feed("One. Three. Four", final: false) == ["Three."])
        #expect(c.feed("One. Three. Four", final: true) == ["Four"])
    }
}

@Suite("voice activity")
struct VADTests {
    func frames(_ db: Float, seconds: Double) -> [(Float, Double)] {
        Array(repeating: (db, 0.02), count: Int(seconds / 0.02))
    }

    @Test func detectsAnUtteranceAndItsEnd() {
        var vad = VoiceActivityDetector()
        var events: [VoiceActivityDetector.Event] = []
        for (db, d) in frames(-70, seconds: 1) + frames(-25, seconds: 1) + frames(-70, seconds: 1) {
            if let e = vad.process(levelDB: db, duration: d) { events.append(e) }
        }
        #expect(events == [.speechStarted, .speechEnded])
    }

    @Test func clicksDontStartSpeechAndPausesDontEndIt() {
        var vad = VoiceActivityDetector()
        var events: [VoiceActivityDetector.Event] = []
        let seq = frames(-70, seconds: 1) + frames(-25, seconds: 0.06) + frames(-70, seconds: 0.5)
            + frames(-25, seconds: 0.6) + frames(-70, seconds: 0.4) + frames(-25, seconds: 0.5)
        for (db, d) in seq { if let e = vad.process(levelDB: db, duration: d) { events.append(e) } }
        #expect(events == [.speechStarted])
    }

    @Test func levelOfASineIsAboutMinus3dBFS() {
        let sine = (0..<1600).map { Float(sin(Double($0) * 0.1)) }
        let db = sine.withUnsafeBufferPointer(VoiceActivityDetector.levelDB)
        #expect(abs(db - (-3.01)) < 0.2)
    }

    @Test func fillersRotate() {
        #expect(CallFillers.pick(language: "fr-FR", turn: 1) == "Je regarde.")
        #expect(CallFillers.pick(language: "en", turn: 5) == "Mm-hm.")
    }
}
