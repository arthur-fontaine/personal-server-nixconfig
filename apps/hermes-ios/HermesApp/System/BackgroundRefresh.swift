import BackgroundTasks
import Foundation
import HermesCore

/// Without push (free team) the best iOS gives is background app refresh: a few wake-ups a
/// day, decided by the system. Each one lets TDLib catch up, which delivers pending `notify`
/// messages as notifications and refreshes the widget (DECISIONS.md).
enum BackgroundRefresh {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "hermes") + ".refresh" }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        schedule()
        // The store is already connecting (the app process started); give TDLib time to sync.
        _ = await MainActor.run { AppModel.shared.store }
        try? await Task.sleep(for: .seconds(20))
        await MainActor.run { AppModel.shared.writeWidgetSnapshot() }
    }
}
