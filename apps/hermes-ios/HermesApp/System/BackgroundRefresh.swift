import BackgroundTasks
import Foundation
import HermesCore

/// Without push (free team), outside the keep-alive window (`BackgroundKeepAlive`), the best iOS
/// gives is background app refresh: a few wake-ups a day, decided by the system. Each one lets
/// TDLib catch up, which delivers pending `notify` messages as notifications (once each:
/// `PostedNotifications`), and refreshes the widget and the Live Activity (DECISIONS.md).
enum BackgroundRefresh {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "hermes") + ".refresh" }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        let started = Date()
        CallLog.shared.log("refresh: woken by iOS")
        // The store is already connecting (the app process started): wait until Telegram is ready,
        // then a moment for TDLib to deliver what arrived (notifies post themselves as they come).
        let store = await MainActor.run { AppModel.shared.store }
        for _ in 0..<40 {
            if await MainActor.run(body: { store.isReady && store.connection == .ready }) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(8))
        await MainActor.run {
            AppModel.shared.writeWidgetSnapshot()
            LiveActivityController.shared.update(state: store.state, store: store)
            // Hermes may be busy again: the window can take over from here.
            BackgroundKeepAlive.shared.evaluate()
            CallLog.shared.log("refresh: done in \(Int(Date().timeIntervalSince(started))) s, connection \(store.connection)")
            CallLog.shared.save()
        }
    }
}
