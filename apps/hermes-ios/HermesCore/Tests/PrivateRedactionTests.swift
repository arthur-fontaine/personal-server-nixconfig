import Foundation
import Testing
@testable import HermesCore

/// design-rules 1.4b: nothing of a private sub-chat's content reaches the lock screen.
@Suite("Private sub-chats on the lock screen")
struct PrivateRedactionTests {
    let approval = ActivityQuestion(id: "a", kind: .approval, title: "Delete taxes/?", detail: "rm -rf taxes/",
                                    options: [.init(id: "deny", label: "Deny", destructive: true),
                                              .init(id: "once", label: "Allow Once", destructive: false)])
    let clarify = ActivityQuestion(id: "c", kind: .clarify, title: "Which bank for the refund?", detail: nil,
                                   options: [.init(id: "1", label: "Boursorama", destructive: false)])

    func state(_ q: ActivityQuestion?) -> HermesActivityAttributes.ContentState {
        .init(status: .working, task: "Filing the 2025 tax return", chat: 455, chatName: "Private chat", since: .now,
              question: q, petMood: .working)
    }

    @Test func notificationBodies() {
        #expect(PrivateRedaction.notification(kind: "message") == .newMessage)
        #expect(PrivateRedaction.notification(kind: nil) == .newMessage)
        #expect(PrivateRedaction.notification(kind: "approval") == .needsYou)
        #expect(PrivateRedaction.notification(kind: "question") == .needsYou)
    }

    @Test func liveActivityKeepsNoContent() {
        let a = PrivateRedaction.activity(state(approval), agentPrivate: true, questionPrivate: true, needsYou: "Hermes needs you")
        #expect(a.task == nil)
        #expect(a.question?.title == "Hermes needs you" && a.question?.detail == nil)
        #expect(a.question?.options == approval.options)
        let c = PrivateRedaction.activity(state(clarify), agentPrivate: true, questionPrivate: true, needsYou: "Hermes needs you")
        #expect(c.question?.options.isEmpty == true)
        let all = String(describing: [a, c])
        for secret in ["tax", "rm -rf", "Boursorama", "refund"] { #expect(!all.contains(secret), "\(secret)") }
    }

    @Test func otherChatsAreUntouched() {
        let s = state(clarify)
        #expect(PrivateRedaction.activity(s, agentPrivate: false, questionPrivate: false, needsYou: "x") == s)
        let snap = SharedSnapshot(petName: "Pip", mood: .working, agentStatus: .working, agentTask: "Lisbon flights",
                                  questionText: "Window or aisle?", spritesheetFile: nil)
        #expect(PrivateRedaction.snapshot(snap, agentPrivate: false, questionPrivate: false, needsYou: "x") == snap)
    }

    @Test func widgetKeepsNoContent() {
        let snap = SharedSnapshot(petName: "Pip", mood: .waiting, agentStatus: .waitingUser, agentTask: "Filing taxes",
                                  questionText: "Which bank for the refund?", spritesheetFile: nil)
        let r = PrivateRedaction.snapshot(snap, agentPrivate: true, questionPrivate: true, needsYou: "Hermes needs you")
        #expect(r.agentTask == nil && r.questionText == "Hermes needs you")
    }
}
