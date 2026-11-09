import XCTest

/// Brief item 6 (Arthur: "+ › Commands" needed a long press; a tap only closed the menu): one tap
/// on the item opens the palette, once the menu has gone.
final class ComposerMenuTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testOneTapOnCommandsOpensThePalette() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion"]
        app.launch()
        let attach = app.descendants(matching: .any)["composer.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        // As on the phone: typing, the keyboard up.
        let field = app.descendants(matching: .any)["composer.field"]
        field.tap()
        field.typeText("a")
        attach.tap()
        let commands = app.buttons["Commands"]
        XCTAssertTrue(commands.waitForExistence(timeout: 3))
        commands.tap()
        XCTAssertTrue(app.navigationBars["Commands"].waitForExistence(timeout: 4), "the palette opens on one tap")
    }
}
