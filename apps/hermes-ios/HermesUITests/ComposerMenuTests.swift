import XCTest

/// "+ › Commands" on Arthur's iPhone: the menu closed and the palette mostly didn't open (one in
/// four taps). The palette is now presented by the chat screen, set straight from the menu item.
final class ComposerMenuTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testOneTapOnCommandsOpensThePaletteEveryTime() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion"]
        app.launch()
        let attach = app.descendants(matching: .any)["composer.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        // As on the phone: typing, the keyboard up.
        let field = app.descendants(matching: .any)["composer.field"]
        field.tap()
        field.typeText("a")
        let palette = app.navigationBars["Commands"]
        for round in 1...5 {
            XCTAssertTrue(attach.waitForExistence(timeout: 3) && attach.isHittable, "round \(round): the composer is back")
            attach.tap()
            let commands = app.buttons["Commands"]
            XCTAssertTrue(commands.waitForExistence(timeout: 3), "round \(round): the menu opens")
            commands.tap() // once, never again
            XCTAssertTrue(palette.waitForExistence(timeout: 4), "round \(round): the palette opens on one tap")
            app.buttons["Close"].firstMatch.tap()
            XCTAssertTrue(palette.waitForNonExistence(timeout: 4), "round \(round): the palette closes")
        }
    }

    /// "/" on an empty composer still opens it.
    func testSlashOpensThePalette() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion"]
        app.launch()
        let field = app.descendants(matching: .any)["composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("/")
        XCTAssertTrue(app.navigationBars["Commands"].waitForExistence(timeout: 4))
    }
}
