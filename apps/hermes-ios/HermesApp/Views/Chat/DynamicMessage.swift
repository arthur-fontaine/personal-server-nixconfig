import HermesCore
import HermesUI
import SwiftUI

/// One of Hermes' messages drawn as the UI it came with (docs/app-protocol.md §8). Its text stays
/// the message's: copied, quoted in a reply, read by VoiceOver as the summary.
struct DynamicMessage: View {
    @Environment(HermesStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let message: ChatMessage
    let spec: UISpec

    var body: some View {
        DynamicUIView(spec: spec, summary: Text("Hermes: \(message.displayText)")) { action in
            switch action {
            case .reply(let text):
                // A normal reply to the UI's message: Hermes gets a turn, and may answer with a new UI.
                do {
                    try await store.reply(text, to: message)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } catch {
                    model.showToast(error.localizedDescription)
                }
            case .open(let url):
                openURL(url)
            case .setState, .unknown:
                break
            }
        }
    }
}
