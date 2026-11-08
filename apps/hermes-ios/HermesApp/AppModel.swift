import ActivityKit
import CoreImage
import HermesCore
import HermesUI
import SwiftUI
import UserNotifications
import WidgetKit

enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case chat, pet, dashboard, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: String(localized: "Chat")
        case .pet: String(localized: "Pet")
        case .dashboard: String(localized: "Dashboard")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .pet: "pawprint"
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .settings: "gearshape"
        }
    }
}

/// App-wide UI state and the glue between the store and the system (notifications, Live
/// Activities, widgets). One per process: App Intents reach it from the Live Activity.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let config: AppConfig
    let store: HermesStore
    var section: AppSection = .chat
    var selectedTopic: TopicID? = .main
    /// The pet's sheet (the pet, what Hermes does, New Pet…, Dashboard, Settings), from the pet in
    /// the toolbar.
    var showPet = false
    /// A section pushed inside the pet sheet on iPhone (`-section dashboard`, `hermes://dashboard`).
    var petPath: [AppSection] = []
    /// The app's one colour, read from the pet's sprite (design-rules 4.2).
    var accent: PetAccent = .fallback
    /// `-catalog <page>`: HermesUI's component catalogue instead of the app (design reviews).
    let catalogPage = AppModel.value("-catalog", in: ProcessInfo.processInfo.arguments).flatMap(CatalogPage.init(rawValue:))
    var showNewSubchat = false
    var showCommands = false
    var callPresented = false
    /// Private sub-chats opened with Face ID this session; cleared when the app goes to the background.
    var unlockedTopics: Set<TopicID> = []
    var toast: String?

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        config = AppConfig.fromBundle(deviceName: UIDevice.current.name)
        let client: any TelegramClient
        if config.demo {
            client = FakeTelegramClient(startsLoggedIn: !arguments.contains("-demoLogin"), withQuestion: !arguments.contains("-noQuestion"),
                                        scene: Self.value("-scene", in: arguments))
        } else {
            client = TDLibTelegramClient(config: config)
        }
        store = HermesStore(client: client, config: config)
        store.hooks.notify = { NotificationService.shared.post($0) }
        store.hooks.stateChanged = { [weak self] state in self?.stateChanged(state) }
        store.hooks.spriteAvailable = { [weak self] pet, url in self?.spriteChanged(pet: pet, url: url) }
        store.start()
        if let hue = Self.value("-petHue", in: arguments).flatMap(Double.init) { Self.recolourBundledPet(degrees: hue) }
        refreshAccent()
        applyLaunchArguments(arguments)
        IntentBridge.shared.answer = { [weak self] questionID, optionID in
            try await self?.answerFromIntent(questionID: questionID, optionID: optionID)
        }
        #if HERMES_PAID
        // Lets Hermes start the Live Activity itself when a turn starts while the app is closed.
        Task { [store] in
            for await token in Activity<HermesActivityAttributes>.pushToStartTokenUpdates {
                _ = try? await store.sendRequest(.pushRegister(token: token, kind: "pushtostart", sandbox: true,
                                                               bundleID: Bundle.main.bundleIdentifier ?? ""), awaitReply: false)
            }
        }
        #endif
    }

    // MARK: Navigation

    func select(_ section: AppSection) { show(section) }

    /// Pet, Dashboard and Settings live in the pet's sheet on iPhone, in the detail column on iPad;
    /// both shells read `section` and `petPath`.
    func show(_ section: AppSection) {
        switch section {
        case .chat: self.section = .chat
        case .pet: showPet = true
        case .dashboard, .settings:
            self.section = section
            petPath = [section]
        }
    }

    func open(topic: TopicID) {
        section = .chat
        selectedTopic = topic
    }

    /// `hermes://chat/<topic>`, `hermes://pet`, `hermes://call` (widgets and notifications).
    func open(_ url: URL) {
        guard url.scheme == "hermes" else { return }
        switch url.host() {
        case "chat": open(topic: TopicID(url.lastPathComponent) ?? .main)
        case "pet": showPet = true
        case "dashboard": show(.dashboard)
        case "call": startCall()
        default: break
        }
    }

    func startCall() { callPresented = true }

    /// A message of the app's own (literals are localized); errors' texts go through the `String` one.
    func showToast(_ resource: LocalizedStringResource) { showToast(String(localized: resource)) }

    @_disfavoredOverload
    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == text { toast = nil }
        }
    }

    // MARK: System glue

    private var lastSnapshot: SharedSnapshot?

    private func stateChanged(_ state: AppState) {
        LiveActivityController.shared.update(state: state, store: store)
        writeWidgetSnapshot()
    }

    private func spriteChanged(pet: PetState, url: URL) {
        refreshAccent()
        writeWidgetSnapshot()
    }

    private func refreshAccent() {
        guard let url = store.spriteURL ?? BundledPet.load()?.spritesheet,
              let frame = SpriteSheet.cached(url: url)?.frame(.idle, 0) else { return }
        accent = PetAccent(sprite: frame)
    }

    /// Demo: another pet's colour, by turning the bundled sprite's hue (`-petHue 200`).
    private static func recolourBundledPet(degrees: Double) {
        guard let url = BundledPet.load()?.spritesheet, let image = SpriteSheet.decode(url) else { return }
        let filter = CIFilter(name: "CIHueAdjust")!
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(degrees * .pi / 180, forKey: kCIInputAngleKey)
        guard let out = filter.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) else { return }
        SpriteSheet.register(SpriteSheet(image: cg), for: url)
    }

    static func value(_ flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func writeWidgetSnapshot() {
        let pet = store.pet
        var spriteFile: String?
        if let url = store.spriteURL ?? BundledPet.load()?.spritesheet {
            spriteFile = SharedContainer.storeSpritesheet(url, petID: pet?.id ?? "pip", version: pet?.version ?? 0, group: config.appGroup)
        }
        let snap = SharedSnapshot(
            petName: pet?.name ?? "Pip", mood: store.petMood, agentStatus: store.agent.status, agentTask: store.agent.task,
            questionText: store.questions.first.map { $0.summary ?? $0.text }, spritesheetFile: spriteFile)
        var comparable = snap
        comparable.updatedAt = lastSnapshot?.updatedAt ?? snap.updatedAt
        guard comparable != lastSnapshot else { return }
        lastSnapshot = snap
        SharedContainer.write(snap, group: config.appGroup)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A Live Activity button may launch the app in the background: wait for Telegram and the
    /// state slot (a few seconds from TDLib's local database) before pressing the button.
    private func answerFromIntent(questionID: String, optionID: String) async throws {
        let deadline = Date.now.addingTimeInterval(20)
        while Date.now < deadline, !(store.isReady && store.questions.contains { $0.id == questionID }) {
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let q = store.questions.first(where: { $0.id == questionID }),
              let option = q.options.first(where: { $0.id == optionID }) else {
            throw TelegramError.server(code: 410, message: String(localized: "This question was already answered."))
        }
        _ = try await store.answer(q, with: option)
    }

    /// Asked once, after login, with a word on why (design.md, "Install → first message").
    var askNotifications: Bool {
        get { store.isReady && !UserDefaults.standard.bool(forKey: "notificationsAsked") && !config.demo }
        set { if !newValue { UserDefaults.standard.set(true, forKey: "notificationsAsked") } }
    }

    func didRegisterForPush(token: Data) {
        #if HERMES_PAID
        Task {
            _ = try? await store.sendRequest(.pushRegister(token: token, kind: "alert", sandbox: true,
                                                           bundleID: Bundle.main.bundleIdentifier ?? ""), awaitReply: false)
        }
        #endif
    }

    /// Screenshot and demo hooks: `-section pet`, `-topic 12`, `-approval`, `-call`.
    private func applyLaunchArguments(_ args: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let s = value("-section").flatMap(AppSection.init(rawValue:)) { show(s) }
        if args.contains("-pet") { showPet = true }
        if let t = value("-topic").flatMap(TopicID.init) { selectedTopic = t }
        if args.contains("-unlocked"), let t = selectedTopic { unlockedTopics.insert(t) }
        if args.contains("-newSubchat") { showNewSubchat = true }
        if args.contains("-commands") { showCommands = true }
        if args.contains("-call") { callPresented = true }
    }
}
