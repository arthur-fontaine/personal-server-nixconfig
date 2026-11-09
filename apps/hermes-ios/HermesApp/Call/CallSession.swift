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
        /// `hearing`: speech detected; `sending`: the transcript is on its way to Hermes.
        case starting, listening, hearing, transcribing, sending, waiting, speaking, ended(String?)
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
    private let voice = CallVoice.current()
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
    private let log = CallLog.shared
    private var observers: [NSObjectProtocol] = []
    /// Microphone levels since the last log line (one every 2 s while listening).
    private var levelWindow: (max: Float, frames: Int, since: Date) = (-100, 0, .now)

    init(store: HermesStore, topic: TopicID = .main, language: String = Locale.preferredLanguages.first ?? "en-US") {
        self.store = store
        self.topic = topic
        self.language = language
    }

    // MARK: Lifecycle

    func start() async {
        log.log("call: start, language \(language), voice \(voice.rawValue)")
        guard await AVAudioApplication.requestRecordPermission() else {
            log.log("call: microphone permission denied")
            phase = .ended(String(localized: "Hermes needs the microphone for calls. Allow it in Settings."))
            return
        }
        log.log("call: microphone permission granted")
        let loadStart = Date()
        if let lfm = await LFMEngineHolder.shared.load() {
            engine = lfm
            log.log("call: LFM loaded in \(Self.ms(since: loadStart)) ms")
        } else {
            log.log("call: LFM not used (\(LFMEngineHolder.shared.lastError ?? "not downloaded")), Apple speech instead")
            guard await AppleVoiceEngine.requestAuthorization() else {
                log.log("call: speech recognition permission denied")
                phase = .ended(String(localized: "Speech recognition is off. Allow it in Settings, or download the voice model."))
                return
            }
            engine = AppleVoiceEngine()
        }
        engineName = engine!.name
        // Screenshot hook: the call screen without the audio engine. On some hosts the simulator's
        // audio unit times out talking to the Mac's audio server and aborts the app (AURemoteIO).
        if ProcessInfo.processInfo.arguments.contains("-noAudio") {
            phase = .listening
            return
        }
        do {
            try configureAudio()
        } catch {
            log.log("call: audio failed: \(error)")
            phase = .ended(String(localized: "Couldn't start audio: \(error.localizedDescription)"))
            return
        }
        observeAudio()
        // Listening starts now, not after Hermes is told: a slow network mustn't eat the first words.
        phase = .listening
        log.log("call: listening")
        await store.setCallActive(true)
    }

    func hangUp() {
        guard phase != .ended(nil) else { return }
        stopSpeaking()
        answerTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .ended(nil)
        log.log("call: ended after \(turnCount) turns")
        log.save()
        Task { await store.setCallActive(false) }
    }

    private func configureAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)
        // Touching inputNode without an input aborts inside AudioToolbox: check first.
        guard session.isInputAvailable else { throw VoiceEngineError.unavailable(String(localized: "No microphone is available.")) }
        // The route before the engine starts: overriding the output port is a route change, and a
        // route change after start reconfigures AVAudioEngine, which stops it — the microphone
        // then went silent for the rest of the call.
        applyRoute()
        let input = audio.inputNode
        // The system's echo cancellation: without it Hermes' own voice would trigger barge-in.
        try input.setVoiceProcessingEnabled(true)
        playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: engine!.outputSampleRate, channels: 1, interleaved: false)
        audio.attach(player)
        audio.connect(player, to: audio.mainMixerNode, format: playFormat)
        try startEngine()
        log.log("call: session \(session.category.rawValue)/\(session.mode.rawValue), \(Self.route(session))")
    }

    /// Taps the microphone in its current format and starts the engine (again after a
    /// configuration change: the format may have changed with the route).
    private func startEngine() throws {
        let input = audio.inputNode
        input.removeTap(onBus: 0)
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw VoiceEngineError.unavailable(String(localized: "No microphone is available."))
        }
        let mic = MicConverter(from: hwFormat)
        log.log("call: mic \(Int(hwFormat.sampleRate)) Hz × \(hwFormat.channelCount), voice processing \(input.isVoiceProcessingEnabled)")
        // @Sendable: the tap runs on the audio thread, not the main actor.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { @Sendable [weak self] buffer, _ in
            guard let samples = mic.convert(buffer) else { return }
            Task { @MainActor [weak self] in self?.handleMic(samples) }
        }
        audio.prepare()
        try audio.start()
        player.play()
    }

    /// The engine stops itself on a route or configuration change, and the system stops audio on
    /// an interruption (a phone call, Siri): start again rather than listen to nothing.
    private func observeAudio() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart(because: "configuration change") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated {
                if type == .ended { self?.restart(because: "interruption ended") } else { self?.log.log("call: interrupted") }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            MainActor.assumeIsolated { self?.log.log("call: route changed (reason \(reason)): \(Self.route(.sharedInstance()))") }
        })
    }

    private func restart(because reason: String) {
        guard !isEnded else { return }
        log.log("call: restarting audio (\(reason)), engine running: \(audio.isRunning)")
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
        } catch {
            log.log("call: restart failed: \(error)")
            lines.append(Line(fromUser: false, text: "⚠️ \(error.localizedDescription)"))
        }
    }

    private func applyRoute() {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
        } catch {
            log.log("call: route override failed: \(error)")
        }
    }

    nonisolated static func route(_ session: AVAudioSession) -> String {
        let r = session.currentRoute
        return "in " + r.inputs.map(\.portType.rawValue).joined(separator: ",") + ", out " + r.outputs.map(\.portType.rawValue).joined(separator: ",")
    }

    nonisolated static func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    // MARK: Listening

    private func handleMic(_ samples: [Float]) {
        guard !muted, phase != .starting, !isEnded else { return }
        level = samples.withUnsafeBufferPointer(VoiceActivityDetector.levelDB)
        logLevels(samples.count)
        let event = vad.process(samples)
        switch event {
        case .speechStarted:
            if phase == .speaking || phase == .waiting {
                // Barge-in: the owner talks over Hermes; stop speaking, keep listening.
                log.log("call: barge-in at \(Int(level)) dB")
                stopSpeaking()
            }
            log.log("call: speech started at \(Int(level)) dB (floor \(Int(vad.noiseFloor)) dB)")
            utterance = preRoll
            phase = .hearing
        case .speechEnded:
            let captured = utterance
            utterance = []
            log.log("call: speech ended, \(captured.count * 1000 / 16_000) ms")
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

    /// One line every 2 s: the loudest level heard and the detector's floor, to tune it from a device.
    private func logLevels(_ frames: Int) {
        levelWindow.max = max(levelWindow.max, level)
        levelWindow.frames += frames
        guard Date().timeIntervalSince(levelWindow.since) >= 2 else { return }
        log.log("call: mic max \(Int(levelWindow.max)) dB, floor \(Int(vad.noiseFloor)) dB, \(levelWindow.frames) frames, \(phase)")
        levelWindow = (-100, 0, .now)
    }

    private func finishUtterance(_ samples: [Float]) async {
        guard let engine, samples.count > 4000 else {
            log.log("call: utterance too short (\(samples.count) samples), ignored")
            phase = .listening
            return
        }
        let started = Date()
        do {
            let text = try await engine.transcribe(samples, language: language)
            log.log("call: transcribed by \(engine.name) in \(Self.ms(since: started)) ms: \(text.count) characters")
            guard !text.isEmpty else { phase = .listening; return }
            lines.append(Line(fromUser: true, text: text))
            turnCount += 1
            phase = .sending
            try await store.sendCallTurn(text, in: topic)
            log.log("call: turn \(turnCount) sent")
            phase = .waiting
            followAnswer(after: store.messages(in: topic).last?.id ?? 0)
        } catch {
            log.log("call: turn failed: \(error)")
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
                // The spoken answer only (brief item 7, as ChatGPT): a details message ("📎") is
                // for reading, and a draft stops being spoken where its details begin.
                let final = store.messages(in: topic).first { !$0.isOutgoing && !$0.isCallDetails && $0.id > sentID }
                let text = MessageCleanup.speakable(final?.text.text ?? store.drafts[topic]?.text.text ?? "")
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
                for try await chunk in engine.synthesize(sentence, language: language, voice: voice) {
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

/// Resamples the microphone to 16 kHz mono on the audio thread (the only place it runs). With
/// voice processing on, the input can have several channels: the first is taken as it is (the
/// processed voice), rather than trusting the converter's channel mapping.
nonisolated final class MicConverter: @unchecked Sendable {
    private let mono: AVAudioFormat?
    private let converter: AVAudioConverter?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var reported = false

    init(from input: AVAudioFormat) {
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false)
        let target = format
        self.mono = mono
        converter = mono.flatMap { AVAudioConverter(from: $0, to: target) }
        if converter == nil { CallLog.shared.log("call: no converter from \(input)") }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter, let mono, let channel = buffer.floatChannelData?[0], buffer.frameLength > 0,
              let first = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return nil }
        first.frameLength = buffer.frameLength
        // Non-interleaved float32 is what the input node delivers; channel 0, as is.
        first.floatChannelData![0].update(from: channel, count: Int(buffer.frameLength))
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return first
        }
        if status == .error, !reported {
            reported = true
            CallLog.shared.log("call: mic conversion failed: \(error?.localizedDescription ?? "?")")
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}
