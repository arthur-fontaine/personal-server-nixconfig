import XCTest

/// Dynamic UI (docs/app-protocol.md §8) in the demo's Lisbon trip: a button's reply reaches the
/// transcript as the owner's reply to the UI's message. With $SCREENSHOT_DIR, it also writes the
/// screens for review (`dynamic-<SCREENSHOT_TAG>-<name>.png`; the appearance is the simulator's).
final class DynamicUIFlowTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var dir: URL? { env["SCREENSHOT_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) } }
    private var tag: String { env["SCREENSHOT_TAG"].flatMap { $0.isEmpty ? nil : $0 } ?? "light" }

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) throws {
        guard let dir else { return }
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "dynamic-\(tag)-\(name).png"))
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + args
        app.launch()
        return app
    }

    func testAButtonRepliesToTheUIsMessage() throws {
        let app = launch(["-noQuestion", "-topic", "44"])
        XCTAssertTrue(app.buttons["Hour by Hour"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        try shot("weather")

        // Up to the hotels: a choice bound to the state, then the button whose reply reads it.
        let memmo = app.buttons["Memmo"]
        for _ in 0..<4 where !memmo.isHittable {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertTrue(memmo.isHittable)
        try shot("hotels")
        memmo.tap()
        let hold = app.buttons["Hold Memmo Alfama"]
        XCTAssertTrue(hold.waitForExistence(timeout: 3))
        hold.tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Hold Memmo Alfama for 3 nights")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        // Sent as a reply: the bubble quotes the hotels message.
        let quote = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Reply to Hermes: Three options")).firstMatch
        XCTAssertTrue(quote.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        try shot("replied")
        app.terminate()
    }

    func testScreensForReview() throws {
        guard dir != nil else { throw XCTSkip("SCREENSHOT_DIR not set") }
        // The weather at the largest accessibility size: nothing truncates, rows stack.
        var app = launch(["-noQuestion", "-topic", "44", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["Hour by Hour"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        try shot("weather-ax5")
        for i in 1...3 {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.8)
            try shot("weather-ax5-up\(i)")
        }
        app.terminate()

        // Every component, page by page.
        app = launch(["-catalog", "dynamic"])
        Thread.sleep(forTimeInterval: 2)
        try shot("catalog-1")
        for i in 2...7 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            try shot("catalog-\(i)")
        }
        app.terminate()
    }
}
