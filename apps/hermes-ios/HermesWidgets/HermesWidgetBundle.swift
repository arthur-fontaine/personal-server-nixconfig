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

struct PetWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PetEntry
    var body: some View { PetWidgetView(s: entry.snapshot, family: family) }
}

struct PetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HermesPet", provider: PetProvider()) { entry in
            PetWidgetEntryView(entry: entry)
                .petAccent(WidgetData.accent(entry.snapshot.spritesheetFile))
                .widgetSystemBackground()
                .widgetURL(URL(string: "hermes://chat/0"))
        }
        .configurationDisplayName("Pet")
        .description("Your Hermes pet and what Hermes is doing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Live Activity / Dynamic Island

struct HermesLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesActivityAttributes.self) { context in
            LockScreenActivity(attributes: context.attributes, state: context.state)
                .petAccent(WidgetData.accent(context.attributes.spritesheetFile))
                .widgetURL(URL(string: "hermes://chat/\(context.state.chat)"))
        } dynamicIsland: { context in
            let st = context.state
            return DynamicIsland {
                // One row under the sensor: beside it (leading, trailing) and under it (center)
                // are different heights, so the pet, the words and the timer never lined up.
                DynamicIslandExpandedRegion(.bottom) {
                    VGroup(spacing: .s) {
                        HGroup(spacing: .s) {
                            PetLoop(file: context.attributes.spritesheetFile,
                                    animation: PetAnimation.loop(status: st.status, mood: st.petMood), side: 48)
                            IslandCenter(state: st)
                            if st.question == nil, st.status != .idle {
                                ElapsedTimer(since: st.since).textRole(.caption).tone(.secondary)
                            }
                        }
                        if let q = st.question { QuestionButtons(question: q) }
                    }
                }
            } compactLeading: {
                PetLoop(file: context.attributes.spritesheetFile, animation: PetAnimation.loop(status: st.status, mood: st.petMood),
                        side: 24)
            } compactTrailing: {
                StatusMark(state: st, side: 16, spins: true)
            } minimal: {
                // Sharing the island with another activity: the pet says who it is.
                PetLoop(file: context.attributes.spritesheetFile, animation: PetAnimation.loop(status: st.status, mood: st.petMood),
                        side: 24)
            }
            .widgetURL(URL(string: "hermes://chat/\(st.chat)"))
        }
    }
}

