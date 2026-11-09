import HermesCore
import Intents
import UIKit
import UserNotifications

/// Posts the backend's `notify` messages as local notifications. Their body is the `spoken` text,
/// which is what Siri reads with AirPods. Siri announces only communication and time-sensitive
/// notifications, and both need entitlements a free team doesn't get (DECISIONS.md): on a paid
/// team the notification is donated as an incoming message from "Hermes" (communication
/// notification) and questions are time-sensitive.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    static let questionCategory = "hermes.question"
    /// A call's written detail (`📎 `): to read, so Siri never announces it.
    static let detailCategory = "hermes.detail"

    func requestAuthorization() async {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge, .providesAppNotificationSettings]
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: options)
        #if HERMES_PAID
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: "reply", title: String(localized: "Reply"), options: [],
                                                  textInputButtonTitle: String(localized: "Send"),
                                                  textInputPlaceholder: String(localized: "Message Hermes"))
        let message = UNNotificationCategory(identifier: "hermes.message", actions: [reply], intentIdentifiers: [INSendMessageIntentIdentifier],
                                             options: [.allowAnnouncement])
        let question = UNNotificationCategory(identifier: Self.questionCategory, actions: [], intentIdentifiers: [],
                                              options: [.allowAnnouncement])
        let detail = UNNotificationCategory(identifier: Self.detailCategory, actions: [reply], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([message, question, detail])
    }

    /// A private sub-chat's name never appears in a notification (design-rules 1.4): its title is
    /// "Hermes · Private chat"; otherwise Hermes' own title (which is "Hermes" for private ones too).
    @MainActor
    static func title(for n: NotifyPayload) -> String {
        let store = AppModel.shared.store
        if n.chat != .main, store.isPrivate(n.chat) {
            return "Hermes · \(ChatTitle.name(n.chat, store: store))"
        }
        return n.title ?? "Hermes"
    }

    func post(_ n: NotifyPayload) {
        // In the foreground the app shows it (brief item 9): no banner. In the background, one
        // per message, whether it came live or in a replay after a relaunch.
        if UIApplication.shared.applicationState == .active { return }
        guard PostedNotifications.shared.claim("\(n.chat)-\(n.messageID ?? 0)-\(n.kind ?? "")") else { return }
        CallLog.shared.log("notification: posted (\(n.kind ?? "message"), chat \(n.chat))")
        let content = UNMutableNotificationContent()
        let title = Self.title(for: n)
        content.title = title
        // The spoken variant reads well on screen too, and is what Announce speaks. A private
        // sub-chat's says only that something came (1.4b), whatever the backend sent.
        if n.chat != .main, AppModel.shared.store.isPrivate(n.chat) {
            content.body = switch PrivateRedaction.notification(kind: n.kind) {
            case .newMessage: String(localized: "New message")
            case .needsYou: String(localized: "Hermes needs you")
            }
        } else {
            content.body = n.shownText
        }
        content.sound = .default
        content.threadIdentifier = "topic-\(n.chat)"
        content.targetContentIdentifier = "hermes://chat/\(n.chat)"
        content.userInfo = ["topic": Int(n.chat), "message": n.messageID ?? 0]
        let isQuestion = n.kind == "question" || n.kind == "approval"
        content.categoryIdentifier = isQuestion ? Self.questionCategory : (n.isWrittenDetail ? Self.detailCategory : "hermes.message")
        content.interruptionLevel = n.interruption == .timeSensitive ? .timeSensitive : (n.interruption == .passive ? .passive : .active)
        // Announce reads communication and time-sensitive notifications: a written detail is neither.
        if n.isWrittenDetail { content.interruptionLevel = .active }
        Task {
            let final = n.isWrittenDetail ? content : await Self.asCommunication(content, title: title)
            let request = UNNotificationRequest(identifier: "notify-\(n.chat)-\(n.messageID ?? 0)", content: final, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Paid team: turn the notification into a message from Hermes, so it's a communication
    /// notification (eligible for Announce, shown with the sender's avatar).
    private static func asCommunication(_ content: UNMutableNotificationContent, title: String) async -> UNNotificationContent {
        #if HERMES_PAID
        let sender = INPerson(personHandle: INPersonHandle(value: "hermes", type: .unknown), nameComponents: nil,
                              displayName: title, image: appIconImage(), contactIdentifier: nil, customIdentifier: "hermes")
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                         speakableGroupName: nil, conversationIdentifier: content.threadIdentifier,
                                         serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        return (try? content.updating(from: intent)) ?? content
        #else
        return content
        #endif
    }

    private static func appIconImage() -> INImage? {
        guard let url = BundledPet.load()?.spritesheet, let sheet = SpriteSheet.cached(url: url),
              let frame = sheet.frame(.idle, 0), let png = UIImage(cgImage: frame).pngData() else { return nil }
        return INImage(imageData: png)
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let topic = TopicID((info["topic"] as? Int) ?? 0)
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            if let reply, !reply.isEmpty {
                Task { try? await AppModel.shared.store.send(reply, in: topic) }
            } else {
                AppModel.shared.open(topic: topic)
            }
        }
    }
}
