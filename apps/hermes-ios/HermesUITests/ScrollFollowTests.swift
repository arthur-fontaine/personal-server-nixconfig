import XCTest

/// Brief item 1 (Arthur on his iPhone: scrolling up jumped back to the bottom by itself): the
/// transcript follows its bottom only while the owner is there; once he scrolls up, a streaming
/// draft, its final message and edits don't move what he reads, until he comes back or taps Latest.
final class ScrollFollowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testScrollingUpWhileHermesWritesStaysPut() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion", "-streamDelay", "150"]
        app.launch()
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("hello")
        app.descendants(matching: .any)["composer.send"].tap()
        let draft = app.descendants(matching: .any)["chat.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5), "Hermes starts writing")

        // Up, past the bottom, as a reader does (the keyboard goes with the drag).
        // Started on a message: a drag from the bar's area or the keyboard's suggestions didn't scroll.
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Done: a reminder")).firstMatch.swipeDown(velocity: .slow)
        let latest = app.buttons["Latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3), "away from the bottom")
        Thread.sleep(forTimeInterval: 0.6) // the swipe's deceleration ends
        // One of Hermes' messages on screen ("Hermes: …", one element per message).
        let anchor = try XCTUnwrap(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Hermes: "))
            .allElementsBoundByIndex.first { $0.isHittable }, "a message on screen")
        let label = anchor.label
        let before = anchor.frame

        // Hermes keeps writing, then posts the final message: nothing moves under the reader.
        var samples: [CGFloat] = []
        let deadline = Date().addingTimeInterval(20)
        while draft.exists, Date() < deadline {
            samples.append(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.frame.minY)
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertFalse(draft.exists, "the answer finished")
        Thread.sleep(forTimeInterval: 1)
        samples.append(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.frame.minY)
        for y in samples { XCTAssertEqual(y, before.minY, accuracy: 1, "moved while scrolled up: \(samples)") }
        XCTAssertTrue(latest.exists, "still away from the bottom")

        // Latest brings him back, and the transcript follows again.
        latest.tap()
        XCTAssertTrue(latest.waitForNonExistence(timeout: 3))
    }
}
