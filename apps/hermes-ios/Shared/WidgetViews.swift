import AppIntents
import HermesCore
import HermesUI
import SwiftUI
import UIKit
import WidgetKit

// The widgets' and the Live Activity's views: compiled into the extension, and into the app for
// its review gallery (`-widgetGallery`), which renders them at each family's size.

enum WidgetData {
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "HermesAppGroup") as? String }
    static func snapshot() -> SharedSnapshot { SharedContainer.read(group: group) ?? .placeholder }

    /// The pet's own accent, as the app computes it (design-rules 15.1), from its idle still.
    static func accent(_ file: String?) -> PetAccent {
        guard let file, let url = SharedContainer.stillURL(sheet: file, animation: .idle, circle: false, group: group),
              let image = UIImage(contentsOfFile: url.path)?.cgImage else { return .fallback }
        return PetAccent(sprite: image)
    }
}

/// One frame of the pet: widgets can't animate a sprite, so they show the mood's first frame,
/// centred optically over the first frames of every row (design-rules 14.2) — in the circle of a
/// circular complication, or in its square elsewhere.
/// The pet in a widget or the Live Activity: the still the app rendered for this animation,
/// centred optically (design-rules 14.2), pixel art kept sharp.
struct PetFrame: View {
    let file: String?
    let animation: PetAnimation
    var inCircle = false

    var body: some View {
        if let file, let url = SharedContainer.stillURL(sheet: file, animation: animation, circle: inCircle, group: WidgetData.group),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().interpolation(.none).scaledToFit().accessibilityHidden(true)
        } else {
            Image(systemName: "bird.fill").resizable().scaledToFit().accessibilityHidden(true)
        }
    }
}

extension AgentStatus {
    var widgetSymbol: String {
        switch self {
        case .idle: "moon.zzz"
        case .thinking: "brain"
        case .working: "hammer.fill"
        case .waitingUser: "hand.raised.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

/// The pet widget's content per family (the extension passes its family; the app's review
/// gallery renders each).
struct PetWidgetView: View {
    let s: SharedSnapshot
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                PetFrame(file: s.spritesheetFile, animation: s.mood.animation, inCircle: true)
            }
            .widgetAccentable()
        case .accessoryRectangular:
            HGroup(spacing: .xs) {
                PetFrame(file: s.spritesheetFile, animation: s.mood.animation).petSquare(.row)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.petName).textRole(.headline).widgetAccentable()
                    Label(s.agentStatus.label, systemImage: s.agentStatus.widgetSymbol).textRole(.caption)
                    Text(s.questionText ?? s.mood.caption).textRole(.caption).lineLimit(1)
                }
            }
        case .accessoryInline:
            Label("\(s.petName): \(s.agentStatus.label)", systemImage: s.agentStatus.widgetSymbol)
        case .systemMedium:
            // The pet in Hermes' state and what Hermes does: a companion, nothing to look after
            // (design-rules 11.1–11.3).
            HGroup(spacing: .m) {
                PetFrame(file: s.spritesheetFile, animation: s.mood.animation).petSquare(.widget)
                VGroup(spacing: .xxs) {
                    Text(s.petName).textRole(.headline)
                    Label(s.questionText ?? s.agentTask ?? s.mood.caption, systemImage: s.agentStatus.widgetSymbol)
                        .textRole(.subheadline).tone(.secondary).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
        default:
            VGroup(alignment: .center, spacing: .xxs) {
                PetFrame(file: s.spritesheetFile, animation: s.mood.animation).petFill()
                Text(s.petName).textRole(.headline).lineLimit(1)
                Label(s.agentStatus.label, systemImage: s.agentStatus.widgetSymbol)
                    .textRole(.caption).tone(.secondary)
            }
        }
    }
}

/// The expanded Dynamic Island's centre: what Hermes does, or that it needs you.
struct IslandCenter: View {
    let state: HermesActivityAttributes.ContentState

    var body: some View {
        VGroup(spacing: .xxs) {
            Label(state.question != nil ? String(localized: "Hermes needs you") : state.status.label, systemImage: state.status.widgetSymbol)
                .textRole(.headline)
            Text(state.question?.title ?? state.task ?? "").textRole(.caption).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LockScreenActivity: View {
    let attributes: HermesActivityAttributes
    let state: HermesActivityAttributes.ContentState

    var body: some View {
        let st = state
        VGroup(spacing: .s) {
            HGroup(spacing: .s) {
                PetFrame(file: attributes.spritesheetFile, animation: st.petMood.animation).petSquare(.activity)
                VGroup(spacing: .xxs) {
                    Label(st.question != nil ? String(localized: "Hermes needs you") : st.status.label, systemImage: st.status.widgetSymbol)
                        .textRole(.headline)
                    Text(st.question?.title ?? st.task ?? (st.status == .idle ? String(localized: "Done") : ""))
                        .textRole(.subheadline).lineLimit(2)
                    // Through ChatTitle on the app side: a private sub-chat arrives as "Private chat".
                    if let name = st.chatName { Text(name).textRole(.caption).tone(.secondary) }
                }
                Spacer(minLength: 0)
                if st.question == nil, st.status != .idle {
                    Text(st.since, style: .timer).textRole(.caption).monospacedDigit().tone(.secondary)
                }
            }
            if let q = st.question {
                if let detail = q.detail { Text(detail).textRole(.code).tone(.secondary).lineLimit(1) }
                QuestionButtons(question: q)
            }
        }
        .widgetInset()
    }
}

/// Answers from the lock screen / Dynamic Island: the same Telegram button press as in the app.
/// Deny-like answers don't ask for Face ID; anything that lets Hermes act does.
struct QuestionButtons: View {
    let question: ActivityQuestion

    var body: some View {
        HGroup(spacing: .xs) {
            ForEach(question.options, id: \.id) { o in
                if o.destructive {
                    Button(intent: DeclineQuestionIntent(questionID: question.id, optionID: o.id)) { AnswerLabel(o.label) }
                        .answerButton(destructive: true)
                } else {
                    Button(intent: AnswerQuestionIntent(questionID: question.id, optionID: o.id)) { AnswerLabel(o.label) }
                        .answerButton(destructive: false)
                }
            }
        }
    }
}
