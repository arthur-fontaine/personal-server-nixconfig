import Foundation

/// Energy-based voice activity detection with an adaptive noise floor: enough for turn-taking on
/// a phone with the system's echo cancellation on. Fed 16 kHz mono frames (any length).
public struct VoiceActivityDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case speechStarted
        /// The utterance ended after this much trailing silence.
        case speechEnded
    }

    public var startThresholdDB: Float = 9      // above the noise floor to count as speech
    public var minSpeech: TimeInterval = 0.18   // to start an utterance (and to barge in)
    public var endSilence: TimeInterval = 0.7   // protocol §6's turn end
    public let sampleRate: Double

    public private(set) var inSpeech = false
    private var noiseFloorDB: Float = -60
    private var speechRun: TimeInterval = 0
    private var silenceRun: TimeInterval = 0

    public init(sampleRate: Double = 16_000) { self.sampleRate = sampleRate }

    public static func levelDB(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -100 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        return 20 * log10(max(rms, 1e-7))
    }

    public mutating func process(_ samples: [Float]) -> Event? {
        samples.withUnsafeBufferPointer { process(levelDB: Self.levelDB($0), duration: Double(samples.count) / sampleRate) }
    }

    public mutating func process(levelDB: Float, duration: TimeInterval) -> Event? {
        let loud = levelDB > noiseFloorDB + startThresholdDB && levelDB > -50
        if !loud {
            // The floor follows quiet stretches quickly and loud ones slowly.
            noiseFloorDB = noiseFloorDB * 0.95 + levelDB * 0.05
        } else {
            noiseFloorDB = noiseFloorDB * 0.998 + levelDB * 0.002
        }
        if inSpeech {
            if loud { silenceRun = 0 } else { silenceRun += duration }
            if silenceRun >= endSilence {
                inSpeech = false
                speechRun = 0
                silenceRun = 0
                return .speechEnded
            }
        } else {
            if loud { speechRun += duration } else { speechRun = max(0, speechRun - duration) }
            if speechRun >= minSpeech {
                inSpeech = true
                silenceRun = 0
                return .speechStarted
            }
        }
        return nil
    }

    public mutating func reset() {
        inSpeech = false
        speechRun = 0
        silenceRun = 0
    }
}

/// Short acknowledgements spoken while Hermes thinks, so silence doesn't read as a dropped call.
public enum CallFillers {
    public static let english = ["Mm-hm.", "Let me check.", "One moment.", "Okay, looking into it.", "Sure, give me a second."]
    public static let french = ["Mm-hm.", "Je regarde.", "Un instant.", "D'accord, je vérifie.", "Une seconde."]

    public static func pick(language: String, turn: Int) -> String {
        let list = language.hasPrefix("fr") ? french : english
        return list[turn % list.count]
    }
}
