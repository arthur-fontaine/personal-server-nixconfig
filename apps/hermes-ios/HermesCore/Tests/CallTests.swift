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

@Suite("call voice")
struct CallVoiceTests {
    @Test func ttsPromptNamesTheVoiceAndLanguage() {
        let female = LFMPrompt.tts("Bonjour.", language: "fr-FR", voice: .female)
        #expect(female.contains("<|im_start|>system\nPerform TTS in French using a female voice.<|im_end|>"))
        #expect(female.contains("<|im_start|>user\nBonjour.<|im_end|>"))
        #expect(female.hasPrefix("<|startoftext|>"))
        #expect(female.hasSuffix("<|im_start|>assistant\n<think></think><|audio_start|>"))
        #expect(LFMPrompt.tts("Hi.", language: "en-US", voice: .male).contains("Perform TTS in American English using a male voice."))
        #expect(LFMPrompt.tts("Hi.", language: "en-GB", voice: .male).contains("Perform TTS in British English using a male voice."))
    }

    @Test func asrPromptNamesTheLanguage() {
        let p = LFMPrompt.asr(language: "fr-FR", marker: "<__media__>")
        #expect(p == "<|im_start|>system\nPerform ASR in French.<|im_end|>\n<|im_start|>user\n<__media__><|im_end|>\n<|im_start|>assistant\n<think></think>")
    }

    @Test func femaleByDefaultAndPersisted() throws {
        let defaults = try #require(UserDefaults(suiteName: "CallVoiceTests"))
        defaults.removePersistentDomain(forName: "CallVoiceTests")
        #expect(CallVoice.current(defaults) == .female)
        defaults.set(CallVoice.male.rawValue, forKey: CallVoice.defaultsKey)
        #expect(CallVoice.current(defaults) == .male)
        defaults.set("robot", forKey: CallVoice.defaultsKey)
        #expect(CallVoice.current(defaults) == .female)
        defaults.removePersistentDomain(forName: "CallVoiceTests")
    }

    @Test func appleVoiceOfTheGenderRegionThenQuality() {
        let voices = [
            CallVoice.Candidate(identifier: "amelie", language: "fr-CA", isMale: false, quality: 3),
            CallVoice.Candidate(identifier: "audrey", language: "fr-FR", isMale: false, quality: 1),
            CallVoice.Candidate(identifier: "thomas", language: "fr-FR", isMale: true, quality: 1),
            CallVoice.Candidate(identifier: "thomas-hq", language: "fr-FR", isMale: true, quality: 2),
            CallVoice.Candidate(identifier: "samantha", language: "en-US", isMale: false, quality: 2),
        ]
        #expect(CallVoice.female.pick(from: voices, language: "fr-FR") == "audrey")
        #expect(CallVoice.male.pick(from: voices, language: "fr_FR") == "thomas-hq")
        #expect(CallVoice.female.pick(from: voices, language: "fr-BE") == "amelie")
        #expect(CallVoice.male.pick(from: voices, language: "en-US") == nil)
    }
}
