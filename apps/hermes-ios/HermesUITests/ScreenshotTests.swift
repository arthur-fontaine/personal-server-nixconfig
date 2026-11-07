import XCTest

/// Not assertions: a tour of every screen in both orientations, written as PNGs to
/// $SCREENSHOT_DIR (simulator processes can write to the host's /tmp). Run with
/// `scripts/screenshots.sh`; skipped without the variable.
final class ScreenshotTests: XCTestCase {
    private var dir: URL?

    override func setUp() {
        continueAfterFailure = true
        dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"].map { URL(filePath: $0) }
    }

    private func shoot(_ name: String, _ args: [String], orientation: UIDeviceOrientation, wait: TimeInterval = 3) throws {
        guard let dir else { throw XCTSkip("SCREENSHOT_DIR not set") }
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-demo"] + args
        app.launch()
        Thread.sleep(forTimeInterval: wait)
        // Permission prompts (microphone, speech) belong to SpringBoard: accept them for the tour.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 where springboard.buttons["Allow"].waitForExistence(timeout: 1) {
            springboard.buttons["Allow"].tap()
            Thread.sleep(forTimeInterval: 1.5)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let o = orientation.isLandscape ? "land" : "port"
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(device)-\(o)-\(name).png"))
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
        ("call", ["-noQuestion", "-call"]),
    ]

    /// A reply mid-stream, and the Live Activity (Dynamic Island) once the app is in the background.
    func testStreamingAndLiveActivity() throws {
        guard let dir else { throw XCTSkip("SCREENSHOT_DIR not set") }
        XCUIDevice.shared.orientation = .portrait
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion"]
        app.launch()
        let field = app.textFields["Message Hermes"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("How's the server doing?")
        app.buttons["Send"].tap()
        Thread.sleep(forTimeInterval: 1.6)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(device)-port-streaming.png"))
        Thread.sleep(forTimeInterval: 4)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(device)-port-streamed.png"))
        app.terminate()

        app.launchArguments = ["-demo"]
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(device)-port-liveactivity.png"))
    }

    func testPortrait() throws {
        for (name, args) in Self.screens { try shoot(name, args, orientation: .portrait) }
    }

    func testLandscape() throws {
        for (name, args) in Self.screens { try shoot(name, args, orientation: .landscapeLeft) }
    }
}
