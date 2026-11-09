import ActivityKit
import HermesCore
import Foundation

/// One Live Activity while Hermes works or waits for an answer, ended a little after it goes
/// idle. Updated locally from the `state` slot while the app runs; with a paid team the backend
/// also pushes updates (the activity's push token goes to Hermes as `push.register`).
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<HermesActivityAttributes>?
    private var endTask: Task<Void, Never>?
    /// When the content was last given a stale date.
    private var renewedAt = Date.distantPast

    /// The activity a previous process started (the app was suspended or killed meanwhile) is
    /// this one's: adopt it rather than start a second; end any extra.
    init() {
        let existing = Activity<HermesActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        activity = existing.first
        for extra in existing.dropFirst() {
            nonisolated(unsafe) let extra = extra
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The content holds `KeepAlivePolicy.liveActivityStale`, then iOS shows it as stale rather
    /// than a status no one can update any more (brief item 9). Renewed each minute while the
    /// app runs and Telegram is connected.
    private static var staleDate: Date { .now.addingTimeInterval(KeepAlivePolicy.liveActivityStale) }

    func renew(connected: Bool) {
        guard connected, let current = activity, current.activityState == .active || current.activityState == .stale,
              Date.now.timeIntervalSince(renewedAt) >= 50 else { return }
        renewedAt = .now
        nonisolated(unsafe) let activity = current
        let content = activity.content.state
        Task { await activity.update(ActivityContent(state: content, staleDate: Self.staleDate)) }
    }

    func update(state: AppState, store: HermesStore) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let agent = state.agent ?? AgentState(status: .idle)
        let raw = HermesActivityAttributes.ContentState(
            status: agent.status, task: agent.task, chat: agent.chat ?? .main,
            // Through ChatTitle: a private sub-chat is "Private chat" on the lock screen too (1.4).
            chatName: (agent.chat ?? .main) == .main ? nil : ChatTitle.name(agent.chat!, store: store),
            since: agent.since ?? .now, question: state.question.map(ActivityQuestion.init),
            petMood: store.petMood)
        // A private sub-chat's task and question stay in the app (1.4b).
        let content = PrivateRedaction.activity(raw, agentPrivate: store.isPrivate(agent.chat ?? .main),
                                                questionPrivate: state.question.map { store.isPrivate($0.chat) } ?? false,
                                                needsYou: String(localized: "Hermes needs you"))
        let active = agent.status != .idle || !state.questions.isEmpty

        if active {
            endTask?.cancel()
            endTask = nil
            if let activity, activity.activityState == .active || activity.activityState == .stale {
                // Activity isn't Sendable; it is only ever touched from the main actor here.
                nonisolated(unsafe) let activity = activity
                renewedAt = .now
                Task { await activity.update(ActivityContent(state: content, staleDate: Self.staleDate,
                                                             relevanceScore: content.question != nil ? 100 : 50),
                                             alertConfiguration: alert(for: content, previous: activity.content.state)) }
            } else {
                start(content, store: store)
            }
        } else if let current = activity, endTask == nil {
            nonisolated(unsafe) let activity = current
            // Let "Done" show a moment, then go.
            Task { await activity.update(ActivityContent(state: content, staleDate: nil)) }
            endTask = Task {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(60)))
                self.activity = nil
                self.endTask = nil
            }
        }
    }

    private func start(_ content: HermesActivityAttributes.ContentState, store: HermesStore) {
        let pet = store.pet
        let source = store.spriteURL ?? BundledPet.load()?.spritesheet
        let sprite = source.flatMap {
            SharedContainer.storeSpritesheet($0, petID: pet?.id ?? "pip", version: pet?.version ?? 0, group: store.config.appGroup)
        }
        if let sprite, let source { PetStills.ensure(sheet: sprite, source: source, group: store.config.appGroup) }
        let attributes = HermesActivityAttributes(petName: pet?.name ?? "Pip", spritesheetFile: sprite)
        #if HERMES_PAID
        let pushType: PushType? = .token
        #else
        let pushType: PushType? = nil
        #endif
        do {
            activity = try Activity.request(attributes: attributes, content: ActivityContent(state: content, staleDate: Self.staleDate), pushType: pushType)
            renewedAt = .now
            #if HERMES_PAID
            if let activity {
                Task {
                    for await token in activity.pushTokenUpdates {
                        var req = AppRequest.pushRegister(token: token, kind: "liveactivity", sandbox: true, bundleID: Bundle.main.bundleIdentifier ?? "")
                        req.payload["activity_id"] = .string(activity.id)
                        _ = try? await store.sendRequest(req, awaitReply: false)
                    }
                }
            }
            #endif
        } catch {
            activity = nil
        }
    }

    /// Alert (lights the screen, plays a sound) only when a new question arrives.
    private func alert(for new: HermesActivityAttributes.ContentState, previous: HermesActivityAttributes.ContentState) -> AlertConfiguration? {
        guard let q = new.question, q.id != previous.question?.id else { return nil }
        return AlertConfiguration(title: "Hermes needs you", body: LocalizedStringResource(stringLiteral: q.title), sound: .default)
    }
}
