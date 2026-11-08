import HermesCore
import HermesUI
import SwiftUI
import WidgetKit

/// `-widgetGallery`: the widgets and the Live Activity, as the extension draws them, at each
/// family's size — for the review tour, the Home and Lock Screens not being scriptable.
struct WidgetGallery: View {
    let sprite: String?

    private var working: SharedSnapshot {
        SharedSnapshot(petName: "Pip", mood: .working, agentStatus: .working, agentTask: String(localized: "Pruning old backups"),
                       questionText: nil, spritesheetFile: sprite)
    }
    private var waiting: SharedSnapshot {
        SharedSnapshot(petName: "Pip", mood: .waiting, agentStatus: .waitingUser, agentTask: nil,
                       questionText: String(localized: "Delete 41 old snapshots?"), spritesheetFile: sprite)
    }
    private var attributes: HermesActivityAttributes { HermesActivityAttributes(petName: "Pip", spritesheetFile: sprite) }
    private var question: HermesActivityAttributes.ContentState {
        .init(status: .waitingUser, task: nil, chat: .main, chatName: nil, since: .now,
              question: ActivityQuestion(id: "q1", kind: .approval, title: String(localized: "Delete 41 old snapshots?"),
                                         detail: "restic forget --keep-within 90d --prune",
                                         options: [.init(id: "deny", label: String(localized: "Deny"), destructive: true),
                                                   .init(id: "once", label: String(localized: "Allow Once"), destructive: false)]),
              petMood: .waiting)
    }
    private var task: HermesActivityAttributes.ContentState {
        .init(status: .working, task: String(localized: "Pruning old backups"), chat: 31, chatName: String(localized: "Private chat"),
              since: .now.addingTimeInterval(-74), question: nil, petMood: .working)
    }

    var body: some View {
        ScrollView {
            VGroup(alignment: .center, spacing: .l) {
                section("Home Screen") {
                    PetWidgetView(s: working, family: .systemSmall).widgetCanvas(.systemSmall)
                    PetWidgetView(s: waiting, family: .systemMedium).widgetCanvas(.systemMedium)
                }
                section("Lock Screen") {
                    HGroup(spacing: .m) {
                        PetWidgetView(s: working, family: .accessoryCircular).widgetCanvas(.accessoryCircular)
                        PetWidgetView(s: waiting, family: .accessoryRectangular).widgetCanvas(.accessoryRectangular)
                    }
                    PetWidgetView(s: working, family: .accessoryInline).widgetCanvas(.accessoryInline)
                }
                section("Live Activity") {
                    LockScreenActivity(attributes: attributes, state: question).activityCanvas()
                    LockScreenActivity(attributes: attributes, state: task).activityCanvas()
                }
                section("Dynamic Island") {
                    HGroup(spacing: .xs) {
                        PetFrame(file: sprite, animation: PetMood.working.animation, small: true).petSquare(.island)
                        Spacer(minLength: 0)
                        Image(systemName: AgentStatus.working.widgetSymbol)
                    }
                    .inset(.horizontal, .s)
                    .islandCanvas(.compact)
                    VGroup(spacing: .s) {
                        HGroup(spacing: .s) {
                            PetFrame(file: sprite, animation: PetMood.waiting.animation, small: true).petSquare(.activity)
                            IslandCenter(state: question)
                        }
                        QuestionButtons(question: question.question!)
                    }
                    .islandCanvas(.expanded)
                }
            }
            .inset(.vertical, .l)
            .frame(maxWidth: .infinity)
        }
        .groupedBackground()
    }

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> C) -> some View {
        VGroup(alignment: .center, spacing: .s) {
            Text(title).textRole(.footnote).tone(.secondary)
            content()
        }
    }
}
