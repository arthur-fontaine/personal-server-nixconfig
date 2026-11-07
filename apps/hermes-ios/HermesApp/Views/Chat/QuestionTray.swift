import HermesCore
import SwiftUI

/// Hermes' open questions for this chat, floating above the composer: the plain-language summary
/// first, the raw command one tap away, and the answers as buttons (design.md, "Approve in app").
struct QuestionTray: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let topic: TopicID

    var body: some View {
        let here = store.questions(in: topic)
        let elsewhere = store.questions.filter { $0.chat != topic }
        VStack(spacing: 8) {
            if let q = here.first {
                QuestionCard(question: q, more: here.count - 1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(q.id)
            }
            if let other = elsewhere.first {
                Button { model.open(topic: other.chat) } label: {
                    Label("Hermes is waiting in \(other.chat == .main ? "the main chat" : store.thread(other.chat)?.name ?? "a sub-chat")",
                          systemImage: "hand.raised.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.glass)
            }
        }
        .animation(.snappy, value: here.map(\.id))
    }
}

struct QuestionCard: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    let question: PendingQuestion
    var more = 0
    @State private var showCommand = false
    @State private var pressing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if more > 0 { Text("+\(more) more").font(.caption).foregroundStyle(.secondary) }
            }
            Text(question.summary ?? question.text)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let command = question.command {
                DisclosureGroup(isExpanded: $showCommand) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(command)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                } label: {
                    Text(showCommand ? "Hide command" : "Show command").font(.footnote.weight(.medium))
                }
                .tint(.secondary)
            }
            options
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var options: some View {
        let opts = question.options
        let layout = opts.count <= 4 && opts.allSatisfy { $0.label.count <= 12 }
            ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        GlassEffectContainer(spacing: 8) {
            layout {
                ForEach(opts) { option in
                    Button { answer(option) } label: {
                        HStack(spacing: 6) {
                            if pressing == option.id { ProgressView().controlSize(.small) }
                            Text(option.label).font(.subheadline.weight(.semibold)).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(option.isDestructive || option.id != opts.first?.id ? AnyButtonStyle(.glass) : AnyButtonStyle(.glassProminent))
                    .tint(option.isDestructive ? .red : nil)
                    .disabled(pressing != nil)
                }
            }
        }
    }

    private var icon: String {
        switch question.kind {
        case .approval: "checkmark.shield"
        case .clarify, .question: "questionmark.bubble"
        case .proposal: "lightbulb"
        }
    }

    private var heading: String {
        switch question.kind {
        case .approval: "Approval needed"
        case .clarify, .question: "Hermes asks"
        case .proposal: "Proposal"
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

/// Picks a glass style at runtime (the first option is the prominent one).
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
