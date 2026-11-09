import XCTest

/// Brief item 8b: Settings › About › Copy Diagnostics puts the call diagnostics on the pasteboard.
final class DiagnosticsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCopyDiagnostics() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-noQuestion", "-section", "settings"]
        app.launch()
        let row = app.descendants(matching: .any)["settings.diagnostics"]
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<6 where !row.isHittable { list.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.staticTexts["Diagnostics copied"].waitForExistence(timeout: 5))
    }
}
