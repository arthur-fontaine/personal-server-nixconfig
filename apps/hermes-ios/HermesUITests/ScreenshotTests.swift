import XCTest

/// Not assertions: a tour of every screen in both orientations, written as PNGs to
/// $SCREENSHOT_DIR (simulator processes can write to the host's /tmp). Run with
/// `scripts/screenshots.sh`; skipped without the variable.
final class ScreenshotTests: XCTestCase {
    private var dir: URL?
    /// `SCREENSHOT_LANGUAGE` (en, fr): also passed to the app, in case the simulator's own differs.
    private var language = "en"

    override func setUp() {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        dir = env["SCREENSHOT_DIR"].map { URL(filePath: $0) }
        language = env["SCREENSHOT_LANGUAGE"].flatMap { $0.isEmpty ? nil : $0 } ?? "en"
    }

    private var languageArguments: [String] {
        ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "fr" ? "fr_FR" : "en_US"]
    }

    private func file(_ device: String, _ orientation: String, _ name: String) -> URL {
        dir!.appending(path: "\(language)-\(device)-\(orientation)-\(name).png")
    }

    private func shoot(_ name: String, _ args: [String], orientation: UIDeviceOrientation, wait: TimeInterval = 3) throws {
        guard dir != nil else { throw XCTSkip("SCREENSHOT_DIR not set") }
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-demo"] + languageArguments + args
        app.launch()
        Thread.sleep(forTimeInterval: wait)
        // Permission prompts (microphone, speech) belong to SpringBoard: accept them for the tour.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Autoriser"])).firstMatch
        for _ in 0..<2 where allow.waitForExistence(timeout: 1) {
            allow.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let o = orientation.isLandscape ? "land" : "port"
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: file(device, o, name))
        app.terminate()
    }

    static let screens: [(String, [String])] = [
        ("chat", []),
        ("chat-idle", ["-noQuestion"]),
        ("subchat", ["-noQuestion", "-topic", "44"]),
        ("private", ["-noQuestion", "-topic", "31"]),
        ("commands", ["-noQuestion", "-commands"]),
        ("newsub", ["-noQuestion", "-newSubchat"]),
        ("pet", ["-noQuestion", "-section", "pet"]),
        ("dashboard", ["-noQuestion", "-section", "dashboard"]),
        ("settings", ["-noQuestion", "-section", "settings"]),
        ("login", ["-demoLogin"]),
        ("call", ["-noQuestion", "-call", "-noAudio"]),
    ]

    /// A reply mid-stream, and the Live Activity (Dynamic Island) once the app is in the background.
    func testStreamingAndLiveActivity() throws {
        guard dir != nil else { throw XCTSkip("SCREENSHOT_DIR not set") }
        XCUIDevice.shared.orientation = .portrait
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion"] + languageArguments
        app.launch()
        // Identifiers, not labels: the tour also runs in French.
        let field = app.textFields["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(language == "fr" ? "Comment va le serveur ?" : "How's the server doing?")
        app.buttons["composer.send"].tap()
        Thread.sleep(forTimeInterval: 1.6)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: file(device, "port", "streaming"))
        Thread.sleep(forTimeInterval: 4)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: file(device, "port", "streamed"))
        app.terminate()

        app.launchArguments = ["-demo"] + languageArguments
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: file(device, "port", "liveactivity"))
    }

    func testPortrait() throws {
        for (name, args) in Self.screens { try shoot(name, args, orientation: .portrait) }
    }

    func testLandscape() throws {
        for (name, args) in Self.screens { try shoot(name, args, orientation: .landscapeLeft) }
    }
}
