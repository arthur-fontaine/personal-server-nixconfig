import HermesCore
import HermesUI
import SwiftUI

/// A message where Hermes asks (approval `ea:`, clarify `cl:`, owner approval `oa:`/`op:`), shown
/// as the question card in its place in the transcript (design-rules 6.1). The card is that
/// message: its answers are its keyboard's buttons, a tap presses them on it as in Telegram, and
/// once answered Hermes edits it, its keyboard goes and it reads as a plain message again. The
/// state's question for it, when there, gives guard's sentence and the raw action.
///
/// Approvals have known answers, named the platform's way (title case, verbs): Allow Once is the
/// primary, Deny destructive beside it, the rest in "…". Other questions: the first
/// non-destructive answer is the primary, destructive ones keep the red role, and beyond two the
/// others go to "…". A clarify's numbered buttons show the choice its text numbers.
struct QuestionCard: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    @State private var pressing: String?

    private struct Answer {
        let button: InlineButton
        let label: String
        let known: LocalizedStringKey?
        var isDestructive: Bool { known == "Deny" || QuestionOption(id: "", label: label).isDestructive }
    }

    var body: some View {
        let (primary, others, more) = layout
        ApprovalCard(question: question, command: command,
                     primary: primary.map { action($0, .primary) },
                     others: others.map { action($0, $0.isDestructive ? .destructive : .secondary) },
                     more: more.map { action($0, $0.isDestructive ? .destructive : .secondary) })
    }

    private var asked: PendingQuestion? { store.question(for: message) }

    /// Guard's sentence (from the message itself, so there's no wait for the state), else the
    /// question without the choices its buttons repeat.
    private var question: String {
        if let parsed = ApprovalText.parse(message.text) { return parsed.sentence }
        if let q = asked {
            let shown = QuestionText.display(q)
            return shown.summary ?? shown.text
        }
        let options = message.buttons.map { QuestionOption(id: $0.id, label: $0.label) }
        return QuestionText.display(PendingQuestion(id: "", text: message.displayText, options: options)).text
    }

    /// The state's raw action when it's there (the message's is cut to fit Telegram's card).
    private var command: String? { asked?.disclosed ?? ApprovalText.parse(message.text)?.action }

    private var answers: [Answer] {
        let choices = Dictionary(message.text.text.components(separatedBy: "\n").compactMap(QuestionText.numbered),
                                 uniquingKeysWith: { a, _ in a })
        return message.buttons.sorted { ($0.row, $0.column) < ($1.row, $1.column) }.map { b in
            Answer(button: b, label: choices[b.label.trimmingCharacters(in: .whitespaces)] ?? b.label, known: Self.knownLabel(b))
        }
    }

    private var layout: (Answer?, [Answer], [Answer]) {
        let all = answers
        let primary = all.first { !$0.isDestructive }
        let destructive = all.filter(\.isDestructive)
        let rest = all.filter { $0.button.id != primary?.button.id && !$0.isDestructive }
        if destructive.count + rest.count <= 1 { return (primary, destructive + rest, []) }
        return (primary, destructive.isEmpty ? [rest[0]] : destructive, destructive.isEmpty ? Array(rest.dropFirst()) : rest)
    }

    private func action(_ a: Answer, _ emphasis: Emphasis) -> Action {
        let busy = pressing == a.button.id
        let perform = { press(a.button) }
        if let key = a.known { return Action(id: a.button.id, key, emphasis: emphasis, isBusy: busy, perform: perform) }
        return Action(id: a.button.id, verbatim: a.label, emphasis: emphasis, isBusy: busy, perform: perform)
    }

    /// Hermes' approval answers (`ea:<choice>:<id>`), named as the platform names them.
    static func knownLabel(_ button: InlineButton) -> LocalizedStringKey? {
        guard case .callback(let data) = button.action else { return nil }
        let parts = String(decoding: data, as: UTF8.self).split(separator: ":")
        guard parts.count >= 2, parts[0] == "ea" else { return nil }
        switch parts[1] {
        case "once": return "Allow Once"
        case "session": return "Allow for This Session"
        case "always": return "Always Allow"
        case "deny": return "Deny"
        default: return nil
        }
    }

    private func press(_ button: InlineButton) {
        pressing = button.id
        Task {
            defer { pressing = nil }
            do {
                let toast = try await store.press(button, on: message)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if let toast, !toast.isEmpty { model.showToast(toast) }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                model.showToast(error.localizedDescription)
            }
        }
    }
}
