import XCTest

/// Settings › Memory on the demo client: the memories, a memory's view, a line's halves, a
/// message; VoiceOver reads each line's range and summary; a private memory is "Private chat".
final class MemoryFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testDrillsDownFromSettingsToAMessage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion", "-section", "settings"]
        app.launch()

        let row = app.descendants(matching: .any)["settings.memory"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let main = app.descendants(matching: .any)["memory.volume.0"]
        XCTAssertTrue(main.waitForExistence(timeout: 10), "the memories load")
        XCTAssertTrue(app.staticTexts["Private chat"].exists, "the locked private memory is listed by its public name")
        XCTAssertFalse(app.staticTexts["Taxes 2026"].exists, "never the private chat's name")
        XCTAssertFalse(app.descendants(matching: .any)["memory.volume.31"].exists, "a locked memory doesn't open")
        main.tap()

        let first = app.descendants(matching: .any)["memory.line.2048+1024"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the view loads")
        XCTAssertEqual(first.label, "Messages 2048 to 3071")
        XCTAssertTrue((first.value as? String)?.hasPrefix("Moved Home Assistant") == true, "VoiceOver reads the summary")

        // The second page comes when the list reaches its end.
        let newest = app.descendants(matching: .any)["memory.line.3669+1"]
        for _ in 0..<6 where !newest.exists { app.swipeUp() }
        XCTAssertTrue(newest.waitForExistence(timeout: 10), "the next page loads")
        XCTAssertEqual(newest.value as? String, "Not summarized yet")

        let line = app.descendants(matching: .any)["memory.line.3664+4"]
        XCTAssertTrue(line.exists)
        line.tap()
        let half = app.descendants(matching: .any)["memory.line.3666+2"]
        XCTAssertTrue(half.waitForExistence(timeout: 10), "a line opens on its halves")
        half.tap()
        let message = app.descendants(matching: .any)["memory.line.3666+1"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.label, "Message 3666")
        message.tap()
        XCTAssertTrue(app.navigationBars["Message 3666"].waitForExistence(timeout: 10), "a one-message line opens the message")
        XCTAssertTrue(app.staticTexts["From"].exists)
    }
}
