import HermesCore
import HermesUI
import SwiftUI

/// Hermes' open question in this chat, as the transcript's last item (design-rules 6.1).
///
/// Approvals have known answers, named the platform's way (title case, verbs): Allow Once is the
/// primary, Deny destructive beside it, the rest in "…". Other questions: the first
/// non-destructive answer is the primary, destructive ones keep the red role, and beyond two the
/// others go to "…". The labels Hermes sends for questions it doesn't know are shown as sent.
struct QuestionCard: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    /// Shown without the choices Telegram's text repeats (`QuestionText`).
    let question: PendingQuestion
    @State private var pressing: String?

    init(question: PendingQuestion) { self.question = QuestionText.display(question) }

    var body: some View {
        let (primary, others, more) = layout
        ApprovalCard(question: question.summary ?? question.text, command: question.command,
                     primary: primary.map(action), others: others.map(action), more: more.map(action))
    }

    private var layout: (QuestionOption?, [QuestionOption], [QuestionOption]) {
        let opts = question.options
        let primary = opts.first(where: { !$0.isDestructive })
        let destructive = opts.filter(\.isDestructive)
        let rest = opts.filter { $0.id != primary?.id && !$0.isDestructive }
        if destructive.count + rest.count <= 1 { return (primary, destructive + rest, []) }
        return (primary, destructive.isEmpty ? [rest[0]] : destructive, destructive.isEmpty ? Array(rest.dropFirst()) : rest)
    }

    private func action(_ option: QuestionOption) -> Action {
        let emphasis: Emphasis = option.id == layout.0?.id ? .primary : (option.isDestructive ? .destructive : .secondary)
        let busy = pressing == option.id
        let perform = { answer(option) }
        if let key = Self.knownLabel(option, kind: question.kind) {
            return Action(id: option.id, key, emphasis: emphasis, isBusy: busy, perform: perform)
        }
        return Action(id: option.id, verbatim: option.label, emphasis: emphasis, isBusy: busy, perform: perform)
    }

    /// Hermes' approval answers (`ea:<id>:…`), named as the platform names them.
    static func knownLabel(_ option: QuestionOption, kind: PendingQuestion.Kind) -> LocalizedStringKey? {
        guard kind == .approval else { return nil }
        switch option.id {
        case "once": return "Allow Once"
        case "session": return "Allow for This Session"
        case "always": return "Always Allow"
        case "deny": return "Deny"
        default: return nil
        }
    }

    private func answer(_ option: QuestionOption) {
        pressing = option.id
        Task {
            defer { pressing = nil }
            do {
                let toast = try await store.answer(question, with: option)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if let toast, !toast.isEmpty { model.showToast(toast) }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                model.showToast(error.localizedDescription)
            }
        }
    }
}
