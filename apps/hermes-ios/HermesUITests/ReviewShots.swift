import XCTest

/// Screens for a design review round (`scripts/review-shots.sh`): `REVIEW_DIR` is where the PNGs
/// go, `REVIEW_TAG` names the variant the script set up (light, dark, ax5, fr, otherpet), and
/// `REVIEW_ARGS` adds launch arguments for it. Skipped without `REVIEW_DIR`.
final class ReviewShots: XCTestCase {
    private var dir: URL!
    private var tag = "light"
    private var extra: [String] = []

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let d = env["REVIEW_DIR"], !d.isEmpty else { throw XCTSkip("REVIEW_DIR not set") }
        dir = URL(filePath: d)
        tag = env["REVIEW_TAG"] ?? "light"
        extra = (env["REVIEW_ARGS"] ?? "").split(separator: " ").map(String.init)
        continueAfterFailure = true
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func launch(_ args: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = device == "ipad" ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-demo"] + args + extra
        app.launch()
        return app
    }

    private func shot(_ name: String) throws {
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appending(path: "\(device)-\(name)-\(tag).png"))
    }

    /// Waits until an element stops moving (the draft's reveal, a sheet's spring).
    private func settle(_ e: XCUIElement) {
        var last = CGRect.null
        for _ in 0..<25 {
            let f = e.frame
            if f == last { return }
            last = f
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    func testChat() throws {
        let app = launch(["-scene", "review"])
        let card = app.descendants(matching: .any)["chat.approval"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        settle(card)
        try shot("chat")
        // What VoiceOver gets: the accessibility tree of the bar and the card (7.2).
        try app.debugDescription.write(to: dir.appending(path: "\(device)-chat-\(tag)-a11y.txt"), atomically: true, encoding: .utf8)
        // The raw command, disclosed.
        let disclosure = app.descendants(matching: .any)["approval.command"]
        if disclosure.exists {
            disclosure.buttons.firstMatch.exists ? disclosure.buttons.firstMatch.tap() : disclosure.tap()
            settle(card)
            app.swipeUp()
            settle(card)
            try shot("chat-command")
        }
    }

    func testChatLandscape() throws {
        let app = launch(["-scene", "review"])
        XCUIDevice.shared.orientation = .landscapeLeft
        let card = app.descendants(matching: .any)["chat.approval"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        settle(card)
        try shot("chat-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    func testChatsMenu() throws {
        let app = launch(["-scene", "review"])
        let title = app.navigationBars.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS %@", ",")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        Thread.sleep(forTimeInterval: 1.2)
        try shot("chatsmenu")
    }

    /// The bar's pet: a tap caresses it (the heart for a second), a long press offers New Pet….
    func testPet() throws {
        let app = launch(["-scene", "review", "-heartHold"])
        let pet = app.buttons.matching(identifier: "toolbar.pet").firstMatch
        XCTAssertTrue(pet.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        // The heart lasts a second: shoot as soon as the item reports the caress.
        pet.tap()
        try shot("pet-caress")
        Thread.sleep(forTimeInterval: 1.5)
        pet.press(forDuration: 0.8)
        // Let the menu finish morphing out of the bar item.
        Thread.sleep(forTimeInterval: 2)
        try shot("pet-menu")
    }

    func testCatalog() throws {
        for page in ["type", "surfaces", "actions", "approval", "chat", "files", "composer", "accent"] {
            let app = launch(["-catalog", page])
            Thread.sleep(forTimeInterval: 2)
            try shot("catalog-\(page)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
            try shot("catalog-\(page)-2")
            app.terminate()
        }
    }
}
