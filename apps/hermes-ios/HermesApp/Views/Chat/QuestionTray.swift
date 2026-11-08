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
                    Label(other.chat == .main ? String(localized: "Hermes is waiting in the main chat")
                          : String(localized: "Hermes is waiting in \(store.thread(other.chat)?.name ?? String(localized: "a sub-chat"))"),
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let question: PendingQuestion
    var more = 0
    @State private var showCommand = false
    @State private var pressing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSizeClass == .compact ? 8 : 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if more > 0 { Text("+\(more) more").font(.caption).foregroundStyle(.secondary) }
            }
            Text(question.summary ?? question.text)
                .font(.body.weight(.medium))
                .lineLimit(verticalSizeClass == .compact ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
            // Landscape iPhone: summary and buttons only, the conversation keeps some room.
            if let command = question.command, verticalSizeClass != .compact {
                DisclosureGroup(isExpanded: $showCommand) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(command)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                } label: {
                    Text(showCommand ? String(localized: "Hide command") : String(localized: "Show command")).font(.footnote.weight(.medium))
                }
                .tint(.secondary)
            }
            options
        }
        .padding(verticalSizeClass == .compact ? 12 : 16)
        .glassEffect(in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var options: some View {
        let opts = question.options
        // One row when every label fits on one line, else two columns, else one: measured, not
        // guessed from the label's length ("Toujours" and "Une fois" don't fit four abreast).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(opts) { optionButton($0, lines: 1) } }
            if opts.count > 2 {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: opts.count, by: 2)), id: \.self) { i in
                        GridRow {
                            optionButton(opts[i], lines: 1)
                            if i + 1 < opts.count { optionButton(opts[i + 1], lines: 1) }
                        }
                    }
                }
            }
            VStack(spacing: 8) { ForEach(opts) { optionButton($0, lines: 2) } }
        }
    }

    /// The card is glass: its buttons are filled, never glass on glass (as in system alerts).
    private func optionButton(_ option: QuestionOption, lines: Int) -> some View {
        Button { answer(option) } label: {
            HStack(spacing: 6) {
                if pressing == option.id { ProgressView().controlSize(.small) }
                Text(option.label).font(.subheadline.weight(.semibold)).lineLimit(lines)
                    .fixedSize(horizontal: lines == 1, vertical: false)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(option.isDestructive || option.id != question.options.first?.id ? AnyButtonStyle(.bordered) : AnyButtonStyle(.borderedProminent))
        .buttonBorderShape(.capsule)
        .tint(option.isDestructive ? .red : nil)
        .disabled(pressing != nil)
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
        case .approval: String(localized: "Approval needed")
        case .clarify, .question: String(localized: "Hermes asks")
        case .proposal: String(localized: "Proposal")
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

/// Picks a button style at runtime (the first option is the prominent one).
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
