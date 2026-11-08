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

    /// iPhone landscape as ruled for design-rules 7.2: the real root view hosted at 874 × 402 pt
    /// with compact height (`-hostedLandscape`); the script turns the capture upright.
    func testChatLandscape() throws {
        let app = launch(["-scene", "review", "-hostedLandscape"])
        let card = app.descendants(matching: .any)["chat.approval"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        settle(card)
        try shot("chat-landscape")
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

    /// Phase 2's screens, each from its launch hook.
    func testScreens() throws {
        let screens: [(String, [String])] = [
            ("settings", ["-noQuestion", "-section", "settings"]),
            ("dashboard", ["-noQuestion", "-section", "dashboard"]),
            ("commands", ["-noQuestion", "-commands"]),
            ("private", ["-noQuestion", "-topic", "31"]),
            ("newsub", ["-noQuestion", "-newSubchat"]),
            ("login", ["-demoLogin"]),
            ("call", ["-noQuestion", "-call", "-noAudio"]),
        ]
        for (name, args) in screens {
            let app = launch(args)
            Thread.sleep(forTimeInterval: 2.5)
            // The call asks for the microphone the first time: accept it (SpringBoard's prompt).
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons
                .matching(NSPredicate(format: "label IN %@", ["Allow", "Autoriser"])).firstMatch
            for _ in 0..<2 where allow.waitForExistence(timeout: 1) { allow.tap(); Thread.sleep(forTimeInterval: 1) }
            try shot(name)
            if name == "dashboard" { app.swipeUp(); Thread.sleep(forTimeInterval: 1); try shot("dashboard-2") }
            if name == "settings" { app.swipeUp(); Thread.sleep(forTimeInterval: 1); try shot("settings-2") }
            if name == "login" {
                app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Telegram")).firstMatch.tap()
                Thread.sleep(forTimeInterval: 1.5)
                try shot("login-phone")
            }
            app.terminate()
        }
    }

    /// The Live Activity on the lock screen / Home Screen and in the Dynamic Island.
    func testLiveActivity() throws {
        let app = launch(["-scene", "review"])
        Thread.sleep(forTimeInterval: 4)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2.5)
        try shot("liveactivity")
        app.terminate()
    }

    /// Replies (16): the context above a reply, the chip after a swipe, the original lit after a tap.
    func testReplies() throws {
        let app = launch(["-noQuestion"])
        Thread.sleep(forTimeInterval: 2.5)
        try shot("replies")
        let bubble = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "call mum")).firstMatch
        if bubble.waitForExistence(timeout: 3) {
            let start = bubble.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 140, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: 1.5)
            try shot("replies-chip")
            app.buttons["Cancel Reply"].tap()
        }
        let context = app.descendants(matching: .any).matching(identifier: "chat.reply").allElementsBoundByIndex.first { $0.isHittable }
        context?.tap()
        Thread.sleep(forTimeInterval: 0.6)
        try shot("replies-original")
        app.terminate()
    }

    /// The widgets and the Live Activity as the extension draws them, at each family's size.
    func testWidgetGallery() throws {
        let app = launch(["-widgetGallery"])
        Thread.sleep(forTimeInterval: 2.5)
        try shot("widgets")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1.5)
        try shot("widgets-2")
        app.terminate()
    }

    func testCatalog() throws {
        for page in ["type", "surfaces", "actions", "approval", "chat", "files", "composer", "accent",
                     "buttons", "lists", "metrics", "call", "onboarding", "bar"] {
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
