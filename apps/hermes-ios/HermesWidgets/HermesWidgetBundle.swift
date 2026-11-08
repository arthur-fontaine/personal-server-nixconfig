import ActivityKit
import AppIntents
import HermesCore
import HermesUI
import SwiftUI
import WidgetKit

@main
struct HermesWidgetBundle: WidgetBundle {
    var body: some Widget {
        PetWidget()
        HermesLiveActivity()
    }
}

// MARK: - Shared rendering

enum WidgetData {
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "HermesAppGroup") as? String }
    static func snapshot() -> SharedSnapshot { SharedContainer.read(group: group) ?? .placeholder }

    static func sheet(_ file: String?) -> SpriteSheet? {
        if let url = SharedContainer.spritesheet(named: file, group: group) { return SpriteSheet.cached(url: url) }
        return nil
    }

    /// The pet's own accent, as the app computes it (design-rules 14.1).
    static func accent(_ file: String?) -> PetAccent {
        sheet(file)?.frame(.idle, 0).map(PetAccent.init(sprite:)) ?? .fallback
    }
}

/// One frame of the pet: widgets can't animate a sprite, so they show the mood's first frame,
/// centred optically over the first frames of every row (design-rules 14.2) — in the circle of a
/// circular complication, or in its square elsewhere.
struct PetFrame: View {
    let file: String?
    let animation: PetAnimation
    var frame = 0
    var inCircle = false

    var body: some View {
        if let sheet = WidgetData.sheet(file), let cg = sheet.frame(animation, frame) {
            CenteredPet(frame: cg, centering: PetCentering.cached("widget-\(file ?? "")") {
                PetAnimation.allCases.compactMap { sheet.frame($0, 0) }
            }, inCircle: inCircle)
        } else {
            Image(systemName: "bird.fill").resizable().scaledToFit()
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

// MARK: - Pet widget (Home Screen + Lock Screen)

struct PetEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot
}

struct PetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PetEntry { PetEntry(date: .now, snapshot: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (PetEntry) -> Void) {
        completion(PetEntry(date: .now, snapshot: WidgetData.snapshot()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PetEntry>) -> Void) {
        // The app reloads the timeline on every change; this refresh only ages the "updated" text.
        completion(Timeline(entries: [PetEntry(date: .now, snapshot: WidgetData.snapshot())], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct PetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HermesPet", provider: PetProvider()) { entry in
            PetWidgetView(entry: entry)
                .petAccent(WidgetData.accent(entry.snapshot.spritesheetFile))
                .widgetSystemBackground()
                .widgetURL(URL(string: "hermes://chat/0"))
        }
        .configurationDisplayName("Pet")
        .description("Your Hermes pet and what Hermes is doing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct PetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PetEntry
    var s: SharedSnapshot { entry.snapshot }

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
                PetFrame(file: s.spritesheetFile, animation: s.mood.animation).petSquare(.activity)
                Spacer(minLength: 0)
                Text(s.petName).textRole(.headline).lineLimit(1)
                Label(s.agentStatus.label, systemImage: s.agentStatus.widgetSymbol)
                    .textRole(.caption).tone(s.agentStatus == .waitingUser ? .accent : .secondary)
            }
        }
    }
}

// MARK: - Live Activity / Dynamic Island

struct HermesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            LockScreenActivity(context: context)
                .petAccent(WidgetData.accent(context.attributes.spritesheetFile))
                .widgetURL(URL(string: "hermes://chat/\(context.state.chat)"))
        } dynamicIsland: { context in
            let st = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PetFrame(file: context.attributes.spritesheetFile, animation: st.petMood.animation).petSquare(.activity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if st.question == nil, st.status != .idle {
                        Text(st.since, style: .timer).textRole(.caption).monospacedDigit().tone(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VGroup(spacing: .xxs) {
                        Label(st.question != nil ? String(localized: "Hermes needs you") : st.status.label, systemImage: st.status.widgetSymbol)
                            .textRole(.headline)
                        Text(st.question?.title ?? st.task ?? "").textRole(.caption).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let q = st.question { QuestionButtons(question: q) }
                }
            } compactLeading: {
                PetFrame(file: context.attributes.spritesheetFile, animation: st.petMood.animation).petSquare(.island)
            } compactTrailing: {
                Image(systemName: st.status.widgetSymbol)
            } minimal: {
                Image(systemName: st.status.widgetSymbol)
            }
            .widgetURL(URL(string: "hermes://chat/\(st.chat)"))
        }
    }
}

struct LockScreenActivity: View {
    let context: ActivityViewContext<HermesActivityAttributes>

    var body: some View {
        let st = context.state
        VGroup(spacing: .s) {
            HGroup(spacing: .s) {
                PetFrame(file: context.attributes.spritesheetFile, animation: st.petMood.animation).petSquare(.activity)
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
