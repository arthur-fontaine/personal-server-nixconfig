import XCTest

/// design-rules 16: reply to a message by swiping it or from its menu, see the chip, send; tap a
/// reply's context to reach its original. On the demo client: nothing leaves the simulator.
final class ReplyFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion"] + extra
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
        let chip = app.descendants(matching: .any).matching(identifier: "composer.reply").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "swiping a message shows the reply chip")
        // The last message stays above the chip, the rhythm's gap apart (16.3; round 6's S4).
        Thread.sleep(forTimeInterval: 1)
        let last = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Hermes: Done: a reminder")).firstMatch
        XCTAssertTrue(last.exists)
        XCTAssertLessThanOrEqual(last.frame.maxY, chip.frame.minY - 8, "last message \(last.frame) vs chip \(chip.frame)")
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

    /// The original is off-screen and beyond the first page (Reading list: 70 saves, then a reply
    /// to the first): the tap pages back, scrolls to it and lights it.
    func testTappingAContextPagesToTheOriginal() throws {
        let app = launch(["-topic", "57"])
        // The message itself ("Hermes: Saved: …"), not the context quoting it.
        let original = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Hermes: Saved: “The Pragmatic")).firstMatch
        let context = app.descendants(matching: .any).matching(identifier: "chat.reply").firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertFalse(original.exists && original.isHittable, "the original starts off-screen")
        // Inert while the original is fetched ("loading").
        XCTAssertTrue(context.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        context.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(5)
        while !original.isHittable && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(original.isHittable, "the original is on screen after the tap")
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
