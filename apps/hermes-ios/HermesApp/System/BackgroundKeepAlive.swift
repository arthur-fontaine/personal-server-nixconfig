import AVFoundation
import HermesCore
import SwiftUI

/// A free team has no push (brief item 9, decided by the orchestrator): iOS suspends the app
/// ~30 s after it leaves the screen, TDLib stops, and nothing posts notifications or updates the
/// Live Activity. So, only while it matters (`KeepAlivePolicy`: Hermes working, a question open, a
/// call, or the grace window after Hermes' last activity) and only in the background, the app
/// keeps a silent audio session running — the `audio` background mode. `.playback` with
/// `.mixWithOthers`: it never interrupts or ducks the owner's music, and a mixable session gets
/// no Now Playing entry. Outside the window it stops, and background refresh takes over.
/// A paid team doesn't need it (Hermes pushes): it stays off there.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false
    private var inBackground = false
    private var ticker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let log = CallLog.shared

    /// Re-evaluates the window: on every state change, scene change, and each minute while away.
    func evaluate() {
        let model = AppModel.shared
        let store = model.store
        let open = KeepAlivePolicy.stayAlive(agent: store.agent.status, questions: store.questions.count,
                                             call: model.callPresented, lastActivity: store.lastBotActivity,
                                             grace: Self.grace)
        // A call has its own audio session (which keeps the app running): never two.
        let want = Self.enabled && inBackground && open && !model.callPresented
        if want, !running { start() } else if !want, running { stop(open ? "call or foreground" : "window closed") }
        LiveActivityController.shared.renew(connected: store.connection == .ready)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        inBackground = phase == .background
        ticker?.cancel()
        ticker = nil
        if inBackground {
            // While running, close the grace window on time and renew the Live Activity.
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(self?.nextCheck() ?? 60))
                    self?.evaluate()
                }
            }
        }
        evaluate()
    }

    /// Each minute (the Live Activity's renewal), or sooner when the grace window ends first, so
    /// the session stops on time.
    private func nextCheck() -> TimeInterval {
        guard let last = AppModel.shared.store.lastBotActivity else { return 60 }
        let left = Self.grace - Date().timeIntervalSince(last)
        return left > 0 ? min(60, left + 0.5) : 60
    }

    /// `-keepAliveSeconds <n>`: a short window, for the simulator test.
    /// `-noKeepAlive`: off, for the test's control run.
    static var grace: TimeInterval {
        AppModel.value("-keepAliveSeconds", in: ProcessInfo.processInfo.arguments).flatMap(Double.init)
            ?? KeepAlivePolicy.grace()
    }

    static var enabled: Bool {
        !AppModel.shared.config.paidTeam && !ProcessInfo.processInfo.arguments.contains("-noKeepAlive")
    }

    private func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if engine.attachedNodes.contains(player) == false {
                engine.attach(player)
                let format = engine.mainMixerNode.outputFormat(forBus: 0)
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            // One second of zeros, looped: silent, but an audio session the system sees playing.
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
            silence.frameLength = silence.frameCapacity
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
            running = true
            observe()
            log.log("keepalive: started (Hermes \(AppModel.shared.store.agent.status.rawValue), \(AppModel.shared.store.questions.count) questions)")
        } catch {
            log.log("keepalive: couldn't start: \(error)")
        }
        log.save()
    }

    private func stop(_ reason: String) {
        player.stop()
        engine.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        // A call may own the session now: leave it to the call then.
        if !AppModel.shared.callPresented {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        running = false
        log.log("keepalive: stopped (\(reason))")
        log.save()
    }

    /// Another app's audio (a phone call, an alarm) interrupts ours: start again when it ends,
    /// or the app is suspended in the middle of the window.
    private func observe() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.log.log("keepalive: interruption \(type == .ended ? "ended" : "began")")
                if type == .ended {
                    self.running = false
                    self.start()
                }
            }
        })
    }
}
