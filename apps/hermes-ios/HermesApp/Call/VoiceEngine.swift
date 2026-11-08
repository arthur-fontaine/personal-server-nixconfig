import AVFoundation
import Foundation
import HermesCore
import Speech

/// The call's ears and voice. Hermes (over Telegram) is the brain; the engine only transcribes
/// one utterance and speaks one sentence at a time.
nonisolated protocol VoiceEngine: AnyObject, Sendable {
    var name: String { get }
    /// 16 kHz mono float samples of one utterance → its text.
    func transcribe(_ samples: [Float], language: String) async throws -> String
    /// Speech for `text` in `voice`, as mono float buffers at `outputSampleRate`, streamed as produced.
    func synthesize(_ text: String, language: String, voice: CallVoice) -> AsyncThrowingStream<[Float], Error>
    var outputSampleRate: Double { get }
}

enum VoiceEngineError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let s), .failed(let s): s
        }
    }
}

/// Apple's on-device speech: the fallback when the LFM model isn't downloaded, can't load (an
/// older device, low memory) or the build has no llama.cpp (the simulator).
nonisolated final class AppleVoiceEngine: VoiceEngine, @unchecked Sendable {
    let name = String(localized: "Apple speech")
    let outputSampleRate: Double = 24_000
    private let synthesizer = AVSpeechSynthesizer()

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { throw VoiceEngineError.unavailable(String(localized: "Speech recognition isn't available.")) }
        let request = SFSpeechAudioBufferRecognitionRequest()
        // Stays on the device when the language's model is installed.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw VoiceEngineError.failed(String(localized: "The audio couldn't be prepared."))
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        request.append(buffer)
        request.endAudio()
        return await withCheckedContinuation { c in
            let once = Once()
            recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let result, result.isFinal {
                    once.run { c.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    // "No speech detected" and friends: an empty utterance, the call goes on.
                    once.run { c.resume(returning: "") }
                }
            }
        }
    }

    func synthesize(_ text: String, language: String, voice: CallVoice) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = Self.voice(voice, language: language)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false)!
            let box = ConverterBox()
            synthesizer.write(utterance) { @Sendable buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    continuation.finish()
                    return
                }
                guard let converter = box.converter(from: pcm.format, to: target),
                      let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate) + 64) else { return }
                var fed = false
                _ = converter.convert(to: out, error: nil) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return pcm
                }
                continuation.yield(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))))
            }
        }
    }
}

extension AppleVoiceEngine {
    /// An installed voice of the chosen gender for the language; the language's default voice
    /// when it has none of that gender (`gender` is `.unspecified` on some voices).
    static func voice(_ choice: CallVoice, language: String) -> AVSpeechSynthesisVoice? {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let candidates = installed.filter { $0.gender != .unspecified }.map {
            CallVoice.Candidate(identifier: $0.identifier, language: $0.language, isMale: $0.gender == .male, quality: $0.quality.rawValue)
        }
        if let id = choice.pick(from: candidates, language: language), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

nonisolated final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        if first { body() }
    }
}

nonisolated final class ConverterBox: @unchecked Sendable {
    private var current: AVAudioConverter?
    func converter(from: AVAudioFormat, to: AVAudioFormat) -> AVAudioConverter? {
        if current == nil || current?.inputFormat != from { current = AVAudioConverter(from: from, to: to) }
        return current
    }
}
