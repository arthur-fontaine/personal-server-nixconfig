import XCTest

/// Tapping a notification crashed the app on Arthur's iPhone: the delegate's async methods were
/// nonisolated, and UIKit's completion (snapshot, state restoration) ran off the main thread. Here
/// the real path: the app posts a notification as it leaves the screen, SpringBoard shows it, and
/// it is tapped, or answered from the banner.
final class NotificationTests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion", "-notifyOnBackground", "0"]
        app.launch()
        // The permission prompt is SpringBoard's (only on the first run after an install).
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 5))
        return app
    }

    private func banner() -> XCUIElement {
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "the backup finished")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "the notification is shown")
        return banner
    }

    func testTappingANotificationOpensTheChat() throws {
        let app = launch()
        banner().tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "the app opens")
        // Alive, on the chat: a crash leaves the app not running.
        XCTAssertTrue(app.descendants(matching: .any)["composer.field"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "still running after the notification's completion")
    }

    func testReplyingFromANotificationSendsIt() throws {
        let app = launch()
        let shown = banner()
        // Expanded, the banner offers its text field (the message category's Reply action).
        shown.press(forDuration: 1.2)
        let reply = springboard.buttons["Reply"]
        if reply.waitForExistence(timeout: 3) { reply.tap() }
        let field = springboard.textFields.firstMatch.exists ? springboard.textFields.firstMatch : springboard.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the reply field")
        field.typeText("Thanks")
        springboard.buttons["Send"].tap()
        // The app answered in the background without crashing; back on screen, the reply is there.
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "You: Thanks")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "the reply was sent")
    }
}
