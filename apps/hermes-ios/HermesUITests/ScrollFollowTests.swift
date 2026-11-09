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
        // Started on a message (the one just sent, on screen on every layout): a drag from the
        // bar's area or the keyboard's suggestions didn't scroll.
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "You: hello")).firstMatch
        // The stack re-lays out as the draft grows: wait for a frame to swipe on.
        let ready = Date().addingTimeInterval(5)
        while !(sent.exists && sent.isHittable), Date() < ready { Thread.sleep(forTimeInterval: 0.2) }
        let latest = app.buttons["Latest"]
        // A fixed 300-pt drag (an element's swipe is as long as the element); once more if the
        // first one was taken for a tap.
        for _ in 0..<2 where !latest.exists {
            let start = sent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 300)), withVelocity: .slow, thenHoldForDuration: 0.05)
            _ = latest.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(latest.exists, "away from the bottom")
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

    /// Brief item 2: the composer keeps above the keyboard the gap it has above the home
    /// indicator (the indicator's top is 13 pt above the edge in the 34-pt safe area: 21 → 20).
    func testComposerDoesNotTouchTheKeyboard() throws {
        // The iPhone's: an iPad's home indicator area and keyboard differ.
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone layout") }
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion"]
        app.launch()
        let composer = app.descendants(matching: .any)["composer.capsule"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(window.maxY - composer.frame.maxY, 34, accuracy: 1, "on the home indicator's safe area")
        let field = app.descendants(matching: .any)["composer.field"]
        field.tap()
        field.typeText("a")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        // The keyboard and the gap animate in: wait until both rest.
        var last = CGRect.null
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let now = keyboard.frame.union(composer.frame)
            if keyboard.frame.minY < window.maxY - 100, now == last { break }
            last = now
            Thread.sleep(forTimeInterval: 0.5)
        }
        // The keyboard element's frame starts below its 44-pt suggestion bar (measured on the
        // screenshot: the bar's top is the keyboard's visible top).
        XCTAssertEqual(keyboard.frame.minY - Self.suggestionBar - composer.frame.maxY, 20, accuracy: 1,
                       "composer \(composer.frame) vs keyboard \(keyboard.frame)")
    }

    static let suggestionBar: CGFloat = 44
}
