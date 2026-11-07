import AVFoundation
import Foundation
import HermesCore

/// A voice call with Hermes. The device listens (voice activity detection), transcribes each
/// utterance on device, sends it as a `🎙` call turn in the main chat, then speaks Hermes'
/// streamed answer sentence by sentence as the draft grows. Talking over it stops the speech
/// (barge-in). Nothing but Telegram leaves the phone (DECISIONS.md, [arthur→orch] call mode).
@MainActor
@Observable
final class CallSession {
    enum Phase: Equatable {
        case starting, listening, hearing, transcribing, waiting, speaking, ended(String?)
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        var text: String
    }

    private(set) var phase: Phase = .starting
    private(set) var lines: [Line] = []
    private(set) var engineName = ""
    private(set) var level: Float = 0
    var muted = false
    var speaker = true { didSet { applyRoute() } }

    private let store: HermesStore
    private let topic: TopicID
    private let language: String
    private var engine: (any VoiceEngine)?
    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playFormat: AVAudioFormat!

    private var vad = VoiceActivityDetector()
    private var utterance: [Float] = []
    private var preRoll: [Float] = []
    private var turnCount = 0
    private var answerTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    private var speechQueue: [String] = []
    private var scheduledBuffers = 0

    init(store: HermesStore, topic: TopicID = .main, language: String = Locale.preferredLanguages.first ?? "en-US") {
        self.store = store
        self.topic = topic
        self.language = language
    }

    // MARK: Lifecycle

    func start() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .ended("Hermes needs the microphone for calls. Allow it in Settings.")
            return
        }
        if let lfm = await LFMEngineHolder.shared.load() {
            engine = lfm
        } else {
            guard await AppleVoiceEngine.requestAuthorization() else {
                phase = .ended("Speech recognition is off. Allow it in Settings, or download the voice model.")
                return
            }
            engine = AppleVoiceEngine()
        }
        engineName = engine!.name
        do {
            try configureAudio()
        } catch {
            phase = .ended("Couldn't start audio: \(error.localizedDescription)")
            return
        }
        await store.setCallActive(true)
        phase = .listening
    }

    func hangUp() {
        guard phase != .ended(nil) else { return }
        stopSpeaking()
        answerTask?.cancel()
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .ended(nil)
        Task { await store.setCallActive(false) }
    }

    private func configureAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)
        // Touching inputNode without an input aborts inside AudioToolbox: check first.
        guard session.isInputAvailable else { throw VoiceEngineError.unavailable("No microphone is available.") }
        let input = audio.inputNode
        // The system's echo cancellation: without it Hermes' own voice would trigger barge-in.
        try input.setVoiceProcessingEnabled(true)
        playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: engine!.outputSampleRate, channels: 1, interleaved: false)
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: playFormat)
        let hwFormat = input.outputFormat(forBus: 0)
        let mic = MicConverter(from: hwFormat)
        // @Sendable: the tap runs on the audio thread, not the main actor.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { @Sendable [weak self] buffer, _ in
            guard let samples = mic.convert(buffer) else { return }
            Task { @MainActor [weak self] in self?.handleMic(samples) }
        }
        try audio.start()
        player.play()
        applyRoute()
    }

    private func applyRoute() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    // MARK: Listening

    private func handleMic(_ samples: [Float]) {
        guard !muted, phase != .starting, !isEnded else { return }
        level = samples.withUnsafeBufferPointer(VoiceActivityDetector.levelDB)
        let event = vad.process(samples)
        switch event {
        case .speechStarted:
            if phase == .speaking || phase == .waiting {
                // Barge-in: the owner talks over Hermes; stop speaking, keep listening.
                stopSpeaking()
            }
            utterance = preRoll
            phase = .hearing
        case .speechEnded:
            let captured = utterance
            utterance = []
            phase = .transcribing
            Task { await finishUtterance(captured) }
        case nil:
            break
        }
        if vad.inSpeech {
            utterance += samples
        } else {
            // 300 ms before speech counts as its start (the detector needs a moment to decide).
            preRoll = Array((preRoll + samples).suffix(4800))
        }
    }

    private var isEnded: Bool { if case .ended = phase { true } else { false } }

    private func finishUtterance(_ samples: [Float]) async {
        guard let engine, samples.count > 4000 else { phase = .listening; return }
        do {
            let text = try await engine.transcribe(samples, language: language)
            guard !text.isEmpty else { phase = .listening; return }
            lines.append(Line(fromUser: true, text: text))
            turnCount += 1
            try await store.sendCallTurn(text, in: topic)
            phase = .waiting
            followAnswer(after: store.messages(in: topic).last?.id ?? 0)
        } catch {
            lines.append(Line(fromUser: false, text: "⚠️ \(error.localizedDescription)"))
            phase = .listening
        }
    }

    // MARK: Speaking Hermes' answer

    /// Watches the main chat's draft and the final message, and speaks complete sentences.
    private func followAnswer(after sentID: MessageID) {
        answerTask?.cancel()
        let turn = turnCount
        answerTask = Task {
            var chunker = SpeechChunker()
            var lineIndex: Int?
            var fillerSaid = false
            let started = Date()
            while !Task.isCancelled {
                let final = store.messages(in: topic).first { !$0.isOutgoing && $0.id > sentID }
                let text = final?.text.text ?? store.drafts[topic]?.text.text ?? ""
                if !text.isEmpty {
                    let spoken = FileLink.strip(from: text)
                    if let i = lineIndex { lines[i].text = spoken } else { lines.append(Line(fromUser: false, text: spoken)); lineIndex = lines.count - 1 }
                    enqueue(chunker.feed(text, final: final != nil))
                } else if !fillerSaid, Date().timeIntervalSince(started) > 1.6 {
                    // Silence after the owner spoke reads as a dropped call: acknowledge.
                    fillerSaid = true
                    enqueue([CallFillers.pick(language: language, turn: turn)])
                }
                if final != nil { break }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func enqueue(_ sentences: [String]) {
        guard !sentences.isEmpty else { return }
        speechQueue += sentences
        if speakTask == nil { speakNext() }
    }

    private func speakNext() {
        guard let engine, !speechQueue.isEmpty else {
            speakTask = nil
            if phase == .speaking || phase == .waiting, scheduledBuffers == 0, answerTask == nil || answerTask!.isCancelled {
                phase = .listening
            }
            return
        }
        let sentence = speechQueue.removeFirst()
        phase = .speaking
        speakTask = Task {
            do {
                for try await chunk in engine.synthesize(sentence, language: language) {
                    if Task.isCancelled { break }
                    schedule(chunk)
                }
            } catch {}
            // Synthesis of the next sentence overlaps the playback of this one.
            speakTask = nil
            if !Task.isCancelled { speakNext() }
        }
    }

    private func schedule(_ samples: [Float]) {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        scheduledBuffers += 1
        player.scheduleBuffer(buffer) { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduledBuffers -= 1
                if self.scheduledBuffers == 0, self.speakTask == nil, self.speechQueue.isEmpty, self.phase == .speaking {
                    self.phase = .listening
                }
            }
        }
    }

    private func stopSpeaking() {
        speechQueue.removeAll()
        speakTask?.cancel()
        speakTask = nil
        player.stop()
        scheduledBuffers = 0
        player.play()
    }
}

/// Resamples the microphone to 16 kHz mono on the audio thread (the only place it runs).
nonisolated final class MicConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(from input: AVAudioFormat) {
        converter = AVAudioConverter(from: input, to: format)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return nil }
        var fed = false
        _ = converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
