import ActivityKit
import AppIntents
import HermesCore
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
}

/// One frame of the pet: widgets can't animate a sprite, so they show the mood's first frame.
struct PetFrame: View {
    let file: String?
    let animation: PetAnimation
    var frame = 0

    var body: some View {
        if let cg = WidgetData.sheet(file)?.frame(animation, frame) {
            Image(decorative: cg, scale: 1).resizable().interpolation(.none).scaledToFit()
        } else {
            Image(systemName: "bird.fill").resizable().scaledToFit().padding(6)
        }
    }
}

extension AgentStatus {
    var widgetTint: Color {
        switch self {
        case .idle: .secondary
        case .thinking: .indigo
        case .working: .blue
        case .waitingUser: .orange
        case .error: .red
        }
    }

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
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color.orange.opacity(0.25), Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                }
                .widgetURL(URL(string: "hermes://pet"))
        }
        .configurationDisplayName("Pet")
        .description("Your Hermes pet, its needs, and what Hermes is doing.")
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
                PetFrame(file: s.spritesheetFile, animation: s.mood.animation).padding(4)
            }
            .widgetAccentable()
        case .accessoryRectangular:
            HStack(spacing: 6) {
                PetFrame(file: s.spritesheetFile, animation: s.mood.animation).frame(width: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.petName).font(.headline).widgetAccentable()
                    Label(s.agentStatus.label, systemImage: s.agentStatus.widgetSymbol).font(.caption)
                    if let q = s.questionText { Text(q).font(.caption2).lineLimit(1) }
                    else { Text("Lv \(s.petLevel) · \(s.mood.caption)").font(.caption2) }
                }
            }
        case .accessoryInline:
            Label("\(s.petName): \(s.agentStatus.label)", systemImage: s.agentStatus.widgetSymbol)
        case .systemMedium:
            HStack(spacing: 14) {
                VStack {
                    PetFrame(file: s.spritesheetFile, animation: s.mood.animation).frame(width: 96, height: 104)
                    Text("Lv \(s.petLevel)").font(.caption.weight(.bold)).fontDesign(.rounded)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.petName).font(.headline).fontDesign(.rounded)
                    Label(s.questionText ?? s.agentTask ?? s.agentStatus.label, systemImage: s.agentStatus.widgetSymbol)
                        .font(.caption).foregroundStyle(s.agentStatus.widgetTint).lineLimit(2)
                    needs
                    HStack(spacing: 6) {
                        Button(intent: PetActionIntent(action: .feed)) { Image(systemName: "fork.knife") }
                        Button(intent: PetActionIntent(action: s.asleep ? .wake : .play)) {
                            Image(systemName: s.asleep ? "sun.max.fill" : "tennisball.fill")
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }
        default:
            VStack(spacing: 4) {
                PetFrame(file: s.spritesheetFile, animation: s.mood.animation).frame(height: 78)
                Text(s.petName).font(.headline).fontDesign(.rounded).lineLimit(1)
                Label(s.agentStatus.label, systemImage: s.agentStatus.widgetSymbol)
                    .font(.caption2.weight(.medium)).foregroundStyle(s.agentStatus.widgetTint)
            }
        }
    }

    private var needs: some View {
        VStack(spacing: 3) {
            bar("fork.knife", 1 - s.hunger)
            bar("bolt.fill", s.energy)
            bar("heart.fill", s.happiness)
        }
    }

    private func bar(_ symbol: String, _ v: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).frame(width: 10)
            Gauge(value: v) { EmptyView() }.gaugeStyle(.linearCapacity).tint(v < 0.25 ? .red : .orange)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Live Activity / Dynamic Island

struct HermesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            LockScreenActivity(context: context)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.6))
                .widgetURL(URL(string: "hermes://chat/\(context.state.chat)"))
        } dynamicIsland: { context in
            let st = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PetFrame(file: context.attributes.spritesheetFile, animation: st.petMood.animation)
                        .frame(width: 44, height: 48)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if st.question == nil, st.status != .idle {
                        Text(st.since, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(maxWidth: 56)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(st.question != nil ? "Hermes needs you" : st.status.label, systemImage: st.status.widgetSymbol)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(st.status.widgetTint)
                        Text(st.question?.title ?? st.task ?? "").font(.caption).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let q = st.question { QuestionButtons(question: q) }
                }
            } compactLeading: {
                PetFrame(file: context.attributes.spritesheetFile, animation: st.petMood.animation).frame(width: 22, height: 24)
            } compactTrailing: {
                Image(systemName: st.status.widgetSymbol).foregroundStyle(st.status.widgetTint)
            } minimal: {
                Image(systemName: st.status.widgetSymbol).foregroundStyle(st.status.widgetTint)
            }
            .widgetURL(URL(string: "hermes://chat/\(st.chat)"))
            .keylineTint(st.status.widgetTint)
        }
    }
}

struct LockScreenActivity: View {
    let context: ActivityViewContext<HermesActivityAttributes>

    var body: some View {
        let st = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PetFrame(file: context.attributes.spritesheetFile, animation: st.petMood.animation).frame(width: 48, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Label(st.question != nil ? "Hermes needs you" : st.status.label, systemImage: st.status.widgetSymbol)
                        .font(.headline).foregroundStyle(st.status.widgetTint)
                    Text(st.question?.title ?? st.task ?? (st.status == .idle ? "Done" : ""))
                        .font(.subheadline).lineLimit(2)
                    if let name = st.chatName { Text(name).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if st.question == nil, st.status != .idle {
                    Text(st.since, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(maxWidth: 56)
                }
            }
            if let q = st.question {
                if let detail = q.detail { Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                QuestionButtons(question: q)
            }
        }
        .padding(16)
    }
}

/// Answers from the lock screen / Dynamic Island: the same Telegram button press as in the app.
/// Deny-like answers don't ask for Face ID; anything that lets Hermes act does.
struct QuestionButtons: View {
    let question: ActivityQuestion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(question.options, id: \.id) { o in
                Group {
                    if o.destructive {
                        Button(intent: DeclineQuestionIntent(questionID: question.id, optionID: o.id)) { label(o) }
                            .tint(.red)
                    } else {
                        Button(intent: AnswerQuestionIntent(questionID: question.id, optionID: o.id)) { label(o) }
                            .tint(.orange)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func label(_ o: ActivityQuestion.Option) -> some View {
        Text(o.label).font(.caption.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
    }
}
