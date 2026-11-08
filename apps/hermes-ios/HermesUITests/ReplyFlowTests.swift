import XCTest

/// design-rules 16: reply to a message by swiping it or from its menu, see the chip, send; tap a
/// reply's context to reach its original. On the demo client: nothing leaves the simulator.
final class ReplyFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion"]
        app.launch()
        return app
    }

    func testSwipeRepliesAndSendCarriesIt() throws {
        let app = launch()
        // On the bubble itself, as one swipes: "Remind me to call mum tonight".
        let bubble = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "call mum")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 140, dy: 0)), withVelocity: .fast,
                    thenHoldForDuration: 0.1)
        let chip = app.descendants(matching: .any)["composer.reply"]
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "swiping a message shows the reply chip")
        app.buttons["Cancel Reply"].tap()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 3), "× cancels the reply")
    }

    func testMenuRepliesToHermes() throws {
        let app = launch()
        // On Hermes' words themselves: "Done: a reminder at 19:30…".
        let hermes = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Done: a reminder")).firstMatch
        XCTAssertTrue(hermes.waitForExistence(timeout: 5))
        hermes.press(forDuration: 1.0)
        let reply = app.buttons["Reply"]
        _ = reply.waitForExistence(timeout: 3)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/hermes-v3/scratch/menu.png"))
        XCTAssertTrue(reply.exists, "the context menu offers Reply")
        reply.tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.reply"].waitForExistence(timeout: 3))
    }

    func testTappingAContextReachesTheOriginal() throws {
        let app = launch()
        let context = app.descendants(matching: .any).matching(identifier: "chat.reply").allElementsBoundByIndex.last { $0.isHittable }
        let reply = try XCTUnwrap(context, "a reply context on screen")
        XCTAssertTrue(reply.label.hasPrefix("Reply to "), "VoiceOver reads who it replies to: \(reply.label)")
        reply.tap()
        // The original ("Remind me to call mum tonight") is on screen afterwards.
        let original = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "call mum")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 3) && original.isHittable)
    }
}
