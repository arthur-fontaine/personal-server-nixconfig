import AVFoundation
import Foundation
import HermesCore
import Speech
import UIKit
import UserNotifications

/// Settings › About › Copy Diagnostics (brief item 8b): what Arthur pastes to us when a call
/// does nothing on his phone. The app, the permissions, the voice model and the last call lines;
/// no message content.
@MainActor
enum Diagnostics {
    static func text(store: HermesStore) async -> String {
        let info = Bundle.main.infoDictionary
        let device = UIDevice.current
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let models = VoiceModelStore.shared
        let session = AVAudioSession.sharedInstance()
        var out: [String] = [
            "Hermes \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")), "
                + "\(store.config.paidTeam ? "paid" : "free") team, \(store.config.demo ? "demo" : "Telegram")",
            "\(device.model) \(Self.machine()), iOS \(device.systemVersion), \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB RAM",
            "Connection: \(store.connection), bot: \(store.bot != nil ? "found" : "not found"), App topic: \(store.appTopicID.map(String.init) ?? "none")",
            "Microphone: \(Self.describe(AVAudioApplication.shared.recordPermission)), speech recognition: \(Self.describe(SFSpeechRecognizer.authorizationStatus())), notifications: \(Self.describe(notifications))",
            "Voice model: \(models.state), \(models.onDiskBytes) bytes on disk"
                + (LFMEngineHolder.shared.lastError.map { ", last error: \($0)" } ?? ""),
            "Voice: \(CallVoice.current().rawValue), language \(Locale.preferredLanguages.first ?? "?")",
            "Audio session now: \(session.category.rawValue)/\(session.mode.rawValue), \(CallSession.route(session))",
            "",
            "Last call log lines:",
        ]
        out += CallLog.shared.recent.suffix(150)
        return out.joined(separator: "\n")
    }

    /// "iPhone18,2": the exact model, which `UIDevice.model` doesn't give.
    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func describe(_ p: AVAudioApplication.recordPermission) -> String {
        switch p {
        case .granted: "granted"
        case .denied: "denied"
        default: "not asked"
        }
    }

    static func describe(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "not asked"
        }
    }

    static func describe(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized: "granted"
        case .denied: "denied"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        default: "not asked"
        }
    }
}
