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
    static let aboveComposer: CGFloat = 30
    /// The finger's travel in a frame at the drag's pace, with room for a dropped frame.
    static let fingerStep = 15
    static let splitFrame = 5

    /// Arthur's iPhone: dragging the keyboard down made the transcript jump ("Latest" flickering in
    /// and out) and could leave part of the keyboard on screen. The drag is the system's alone: the
    /// keyboard leaves entirely, and the transcript's offset, sampled each frame by the app
    /// (`-scrollProbe`), only moves with the finger.
    func testDraggingTheKeyboardAwayDoesNotJump() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion", "-scrollProbe"]
        app.launch()
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        let keyboard = app.keyboards.firstMatch
        let transcript = app.descendants(matching: .any)["chat.transcript"]
        for round in 1...3 {
            field.tap()
            // Typing brings up the software keyboard even when the simulator has a hardware one.
            field.typeText("a")
            var last = CGRect.null
            let up = Date().addingTimeInterval(8)
            while Date() < up {
                let now = keyboard.frame
                if now.minY < window.maxY - 100, now == last { break }
                last = now
                Thread.sleep(forTimeInterval: 0.3)
            }
            XCTAssertLessThan(keyboard.frame.minY, window.maxY - 100, "round \(round): the keyboard is up")
            // As Arthur does: from just above the composer down past the screen's bottom, at a
            // finger's pace. The transcript barely scrolls before the finger reaches the keyboard,
            // which then goes with it: the keyboard's own motion is what the transcript sees.
            let bar = app.descendants(matching: .any)["composer.capsule"].frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: window.midX, dy: bar.minY - Self.aboveComposer))
            let end = origin.withOffset(CGVector(dx: window.midX, dy: window.maxY - 2))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)

            // Gone, whole: no keyboard frame left on screen.
            let gone = Date().addingTimeInterval(4)
            while keyboard.exists, keyboard.frame.minY < window.maxY - 1, Date() < gone { Thread.sleep(forTimeInterval: 0.2) }
            XCTAssertFalse(keyboard.exists && keyboard.frame.minY < window.maxY - 1,
                           "round \(round): keyboard left at \(keyboard.frame)")

            // The gesture's frames: the offset went one way, by finger-sized steps.
            let probe = NSPredicate(format: "value BEGINSWITH %@", "frames=")
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: probe, evaluatedWith: transcript)], timeout: 5), .completed)
            let facts = Self.facts(transcript.value as? String ?? "")
            XCTAssertGreaterThan(facts["frames"] ?? 0, 5, "round \(round): sampled \(transcript.value ?? "")")
            // A frame's layout can reach the screen in two steps a few points apart (the keyboard's
            // inset, then the offset): the system's, measured on a bare ScrollView too under load.
            // More than that is something moving the transcript.
            XCTAssertLessThanOrEqual(facts["maxBack"] ?? .max, Self.splitFrame, "round \(round): the offset turned back: \(transcript.value ?? "")")
            XCTAssertLessThanOrEqual(facts["maxStep"] ?? .max, Self.fingerStep, "round \(round): the offset jumped: \(transcript.value ?? "")")
            // "Latest" stays as it was during the drag (it updates once the transcript rests):
            // in the bar, its coming and going moved the composer and the transcript.
            XCTAssertEqual(facts["latest"], 0, "round \(round): Latest changed during the drag: \(transcript.value ?? "")")

            // And nothing moves once the finger has left (no catch-up scroll).
            let message = try XCTUnwrap(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Hermes: "))
                .allElementsBoundByIndex.first { $0.isHittable }, "a message on screen")
            let label = message.label
            let rested = message.frame.minY
            Thread.sleep(forTimeInterval: 1)
            let after = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.frame.minY
            XCTAssertEqual(after, rested, accuracy: 1, "round \(round): moved after the drag")
            // Back to the bottom for the next round.
            if app.buttons["Latest"].exists { app.buttons["Latest"].tap() }
            _ = transcript.waitForExistence(timeout: 1)
        }
    }

    private static func facts(_ value: String) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: value.split(separator: " ").compactMap { pair in
            let kv = pair.split(separator: "=")
            return kv.count == 2 ? (String(kv[0]), Int(kv[1]) ?? 0) : nil
        })
    }

    /// Opening a v4 approval card's command (its sentence makes the card tall) hung the app: the
    /// transcript's height alternated for ever while it followed the bottom. The app must stay
    /// responsive, with the whole command and the answers on screen.
    func testOpeningTheCommandKeepsFollowing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-scene", "review"]
        app.launch()
        let disclosure = app.descendants(matching: .any)["approval.command"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        disclosure.buttons.firstMatch.exists ? disclosure.buttons.firstMatch.tap() : disclosure.tap()
        let code = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "--prune")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5), "the command is disclosed, whole")
        // Each query needs an idle main thread: a hang fails here (XCUITest's 30-s snapshot timeout).
        let allow = app.descendants(matching: .any)["action.once"]
        let shown = Date().addingTimeInterval(5)
        while !(allow.exists && allow.isHittable), Date() < shown { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(allow.isHittable, "the answers stay in view: the transcript followed the card's growth")
        XCTAssertFalse(app.buttons["Latest"].exists)
    }
}
