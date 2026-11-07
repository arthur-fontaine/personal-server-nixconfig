import AppIntents
import Foundation
import HermesCore

/// Compiled into the app and the widget extension. `LiveActivityIntent`s run in the app's
/// process (the system launches it in the background), where `AppModel` sets these handlers;
/// in the widget process they stay nil and are never called.
@MainActor
final class IntentBridge {
    static let shared = IntentBridge()
    var answer: (@MainActor @Sendable (_ questionID: String, _ optionID: String) async throws -> Void)?
    var petAction: (@MainActor @Sendable (PetAction) async throws -> Void)?
}

/// A button of a question in the Live Activity / Dynamic Island: presses the same Telegram
/// button the chat shows, without opening the app.
/// Allowing something runs it: the device must be unlocked (Face ID) first.
struct AnswerQuestionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer Hermes"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Question") var questionID: String
    @Parameter(title: "Option") var optionID: String

    init() {}

    init(questionID: String, optionID: String) {
        self.questionID = questionID
        self.optionID = optionID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentBridge.shared.answer?(questionID, optionID)
        return .result()
    }
}

/// Denying is safe from the lock screen: no unlock needed.
struct DeclineQuestionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Decline"
    static let isDiscoverable = false

    @Parameter(title: "Question") var questionID: String
    @Parameter(title: "Option") var optionID: String

    init() {}

    init(questionID: String, optionID: String) {
        self.questionID = questionID
        self.optionID = optionID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentBridge.shared.answer?(questionID, optionID)
        return .result()
    }
}

/// Feeding or playing with the pet from the widget.
struct PetActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Care for your pet"
    static let isDiscoverable = false

    @Parameter(title: "Action") var action: String

    init() {}
    init(action: PetAction) { self.action = action.rawValue }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let a = PetAction(rawValue: action) { try await IntentBridge.shared.petAction?(a) }
        return .result()
    }
}
