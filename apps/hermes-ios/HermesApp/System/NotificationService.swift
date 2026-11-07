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

    func requestAuthorization() async {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge, .providesAppNotificationSettings]
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: options)
        #if HERMES_PAID
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message Hermes")
        let message = UNNotificationCategory(identifier: "hermes.message", actions: [reply], intentIdentifiers: [INSendMessageIntentIdentifier],
                                             options: [.allowAnnouncement])
        let question = UNNotificationCategory(identifier: Self.questionCategory, actions: [], intentIdentifiers: [],
                                              options: [.allowAnnouncement])
        UNUserNotificationCenter.current().setNotificationCategories([message, question])
    }

    func post(_ n: NotifyPayload) {
        // In the foreground, looking at that chat: no banner.
        if UIApplication.shared.applicationState == .active, AppModel.shared.section == .chat,
           AppModel.shared.selectedTopic == n.chat { return }
        let content = UNMutableNotificationContent()
        content.title = n.title ?? "Hermes"
        // The spoken variant reads well on screen too, and is what Announce speaks.
        content.body = n.speechText
        content.sound = .default
        content.threadIdentifier = "topic-\(n.chat)"
        content.targetContentIdentifier = "hermes://chat/\(n.chat)"
        content.userInfo = ["topic": Int(n.chat), "message": n.messageID ?? 0]
        let isQuestion = n.kind == "question" || n.kind == "approval"
        content.categoryIdentifier = isQuestion ? Self.questionCategory : "hermes.message"
        content.interruptionLevel = n.interruption == .timeSensitive ? .timeSensitive : (n.interruption == .passive ? .passive : .active)
        Task {
            let final = await Self.asCommunication(content, title: n.title ?? "Hermes")
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
