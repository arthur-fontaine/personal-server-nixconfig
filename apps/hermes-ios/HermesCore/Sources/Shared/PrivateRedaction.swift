import Foundation

/// What may leave the app from a private sub-chat (design-rules 1.4, 1.4b): its name is "Private
/// chat", and none of its content reaches a notification, an announcement, the Live Activity or
/// a widget — they say "New message" or "Hermes needs you". The backend redacts too; the app
/// does it again, as the last hop before the lock screen.
public enum PrivateRedaction {
    public enum Generic: Equatable, Sendable {
        case newMessage
        case needsYou
    }

    /// A notification's generic body, by its kind.
    public static func notification(kind: String?) -> Generic {
        kind == "question" || kind == "approval" ? .needsYou : .newMessage
    }

    /// A question as the lock screen may show it: a generic title, no detail, and only an
    /// approval's buttons (standard labels; a clarify's choices are content).
    public static func question(_ q: ActivityQuestion, title: String) -> ActivityQuestion {
        ActivityQuestion(id: q.id, kind: q.kind, title: title, detail: nil, options: q.kind == .approval ? q.options : [])
    }

    public static func activity(_ s: HermesActivityAttributes.ContentState, agentPrivate: Bool, questionPrivate: Bool,
                                needsYou: String) -> HermesActivityAttributes.ContentState {
        var s = s
        if agentPrivate { s.task = nil }
        if questionPrivate, let q = s.question { s.question = question(q, title: needsYou) }
        return s
    }

    public static func snapshot(_ s: SharedSnapshot, agentPrivate: Bool, questionPrivate: Bool, needsYou: String) -> SharedSnapshot {
        var s = s
        if agentPrivate { s.agentTask = nil }
        if questionPrivate, s.questionText != nil { s.questionText = needsYou }
        return s
    }
}
