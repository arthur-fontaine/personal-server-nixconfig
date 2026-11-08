import XCTest

/// The design rules measured on the running app (design-rules 9.5): frames from the
/// accessibility tree, declared radii from HermesUI's `-geometryProbe` values. Runs on any
/// simulator; the review runs it on an iPhone 17 Pro and an iPad Pro 13".
final class GeometryTests: XCTestCase {
    /// One device pixel (½ pt at @2x, ⅓ at @3x): frames are snapped to pixels, so a row split in
    /// equal parts can differ by one.
    let tolerance: CGFloat = 1 / UIScreen.main.scale + 0.01
    /// The spacing scale (HermesUI's `Spacing`).
    let scale: [CGFloat] = [4, 8, 12, 16, 20, 24, 32]

    override func setUp() { continueAfterFailure = true }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-scene", "review", "-geometryProbe"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chat.approval"].waitForExistence(timeout: 10))
        // Let the draft finish revealing and the scroll follow it (polling, not a fixed wait): the
        // draft's frame and the card's must both hold still for a second.
        let draft = app.descendants(matching: .any)["chat.draft"]
        _ = draft.waitForExistence(timeout: 5)
        let card = app.descendants(matching: .any)["chat.approval"]
        var last = (CGRect.zero, CGRect.zero), still = 0
        for _ in 0..<60 where still < 3 {
            let now = (draft.exists ? draft.frame : .zero, card.frame)
            still = now == last ? still + 1 : 0
            last = now
            Thread.sleep(forTimeInterval: 0.35)
        }
        return app
    }

    private func all(_ app: XCUIApplication, _ id: String) -> [XCUIElement] {
        app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex.filter { $0.exists && !$0.frame.isEmpty }
    }

    private func one(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(e.exists, "\(id) missing", file: file, line: line)
        return e
    }

    private func probe(_ e: XCUIElement) -> (radius: CGFloat, inset: CGFloat)? {
        guard let v = e.value as? String else { return nil }
        var r: CGFloat?, i: CGFloat?
        for part in v.split(separator: ";") {
            let kv = part.split(separator: "=")
            guard kv.count == 2, let n = Double(kv[1]) else { continue }
            if kv[0] == "radius" { r = n } else if kv[0] == "inset" { i = n }
        }
        guard let r, let i else { return nil }
        return (r, i)
    }

    /// 2.1: text, code, card and composer start on one x; the owner's bubbles end on the column's
    /// trailing x.
    func testOneLeadingEdge() {
        let app = launch()
        let column = all(app, "chat.hermes").map(\.frame) + all(app, "chat.draft").map(\.frame)
        XCTAssertFalse(column.isEmpty)
        let edges = column + [one(app, "chat.code").frame, one(app, "chat.approval").frame, one(app, "composer").frame]
        let x = edges[0].minX
        for f in edges { XCTAssertEqual(f.minX, x, accuracy: tolerance, "leading edge \(f) ≠ \(x)") }
        // Text reports its glyphs' bounds, so the trailing edge is read on the full-width surfaces.
        let surfaces = [one(app, "chat.code").frame, one(app, "chat.approval").frame, one(app, "composer").frame]
        let trailing = surfaces[0].maxX
        for f in surfaces { XCTAssertEqual(f.maxX, trailing, accuracy: tolerance, "trailing edge \(f)") }
        for b in all(app, "chat.bubble") { XCTAssertEqual(b.frame.maxX, trailing, accuracy: tolerance, "bubble's trailing edge") }
        // iPhone: the system's 16-pt layout margin (reference/metrics.md).
        if UIDevice.current.userInterfaceIdiom == .phone { XCTAssertEqual(x, 16, accuracy: tolerance) }
        // iPad: a readable column, at most 672 pt (2.2).
        XCTAssertLessThanOrEqual(trailing - x, 672 + tolerance)
    }

    /// 2.4: one gap per relation — a turn apart between speakers, closer within a turn — and every
    /// gap on the scale.
    func testRhythm() {
        let app = launch()
        typealias Item = (frame: CGRect, speaker: String)
        var items: [Item] = all(app, "chat.hermes").map { ($0.frame, "hermes") } + all(app, "chat.owner").map { ($0.frame, "owner") }
            + all(app, "chat.draft").map { ($0.frame, "hermes") } + all(app, "chat.approval").map { ($0.frame, "hermes") }
        items.sort { $0.frame.minY < $1.frame.minY }
        XCTAssertGreaterThan(items.count, 4)
        for (a, b) in zip(items, items.dropFirst()) {
            let gap = b.frame.minY - a.frame.maxY
            // 12.3: 24 between turns, 8 between the owner's bubbles, 16 between Hermes' blocks.
            let expected: CGFloat = a.speaker != b.speaker ? 24 : (a.speaker == "owner" ? 8 : 16)
            XCTAssertEqual(gap, expected, accuracy: tolerance, "\(a.speaker)→\(b.speaker) gap \(gap)")
            XCTAssertTrue(scale.contains { abs($0 - gap) <= tolerance }, "gap \(gap) off the scale")
        }
        // The composer never touches the transcript's last item.
        let card = one(app, "chat.approval").frame, composer = one(app, "composer").frame
        XCTAssertEqual(composer.minY - card.maxY, 16, accuracy: tolerance, "the last item breathes above the composer")
    }

    /// 5.3, 6.1, 10.1: the approval's buttons share one height ≥ 44, one row, primary trailing;
    /// "…" is a circle of that height.
    func testApprovalButtons() {
        let app = launch()
        let buttons = ["action.more", "action.deny", "action.once"].map { one(app, $0).frame }
        for b in buttons {
            XCTAssertEqual(b.height, buttons[0].height, accuracy: tolerance, "same height")
            XCTAssertEqual(b.minY, buttons[0].minY, accuracy: tolerance, "one row")
            XCTAssertGreaterThanOrEqual(b.height, 44)
        }
        XCTAssertLessThan(buttons[1].minX, buttons[2].minX, "the primary is trailing")
        XCTAssertEqual(buttons[1].width, buttons[2].width, accuracy: tolerance, "text buttons share the width")
        XCTAssertEqual(buttons[0].width, buttons[0].height, accuracy: 0.5, "“…” is round")
    }

    /// 5.1: inner radius = outer radius − inset, measured: the card's declared corner and inset,
    /// the buttons' real distance from its edges and their real height (capsules).
    func testConcentricCorners() {
        let app = launch()
        let cardElement = one(app, "chat.approval")
        guard let card = probe(cardElement) else { return XCTFail("no geometry probe on the card") }
        let c = cardElement.frame
        let first = one(app, "action.more").frame, last = one(app, "action.once").frame
        XCTAssertEqual(first.minX - c.minX, card.inset, accuracy: tolerance, "leading inset")
        XCTAssertEqual(c.maxX - last.maxX, card.inset, accuracy: tolerance, "trailing inset")
        XCTAssertEqual(c.maxY - last.maxY, card.inset, accuracy: tolerance, "bottom inset")
        XCTAssertEqual(last.height / 2, card.radius - card.inset, accuracy: tolerance, "capsule radius = card radius − inset")
        // A one-line bubble is a capsule.
        if let bubble = all(app, "chat.bubble").first(where: { $0.label.contains("go ahead") || $0.label.contains("vas-y") }),
           let p = probe(bubble) {
            XCTAssertEqual(bubble.frame.height / 2, p.radius, accuracy: tolerance, "one-line bubble is a capsule")
        }
        // Code outside a card: the block minimum, its own 16-pt padding (12.2).
        if let code = probe(one(app, "chat.code")) {
            XCTAssertEqual(code.radius, 16, accuracy: tolerance)
            XCTAssertGreaterThanOrEqual(code.inset, 16)
        }
        XCTAssertGreaterThanOrEqual(card.inset, 20, "the approval card breathes (12.2)")
    }

    /// 5.4: every control we draw at least 44 × 44. Toolbar items are the system's own: they
    /// report the glass item's 36-pt frame, exactly as Apple's trailing bar items do (Reminders'
    /// More, Contacts' Edit: reference/metrics.md), and the bar extends their touch area.
    func testHitTargets() {
        let app = launch()
        var ids = ["composer.attach", "action.once", "action.deny", "action.more", "approval.command"]
        ids.append(app.descendants(matching: .any)["composer.stop"].exists ? "composer.stop" : "composer.send")
        for id in ids {
            let f = one(app, id).frame
            XCTAssertGreaterThanOrEqual(f.width, 44 - tolerance, "\(id) width \(f.width)")
            XCTAssertGreaterThanOrEqual(f.height, 44 - tolerance, "\(id) height \(f.height)")
        }
        let bar = ["toolbar.call", "toolbar.pet"]
        for id in bar {
            let f = one(app, id).frame
            XCTAssertGreaterThanOrEqual(min(f.width, f.height), 36 - tolerance, "\(id) is smaller than a system bar item: \(f)")
        }
    }

    /// 3.4: at the largest accessibility size the answers stack (primary first) and nothing leaves
    /// the screen.
    func testAccessibilitySize() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let primary = one(app, "action.once").frame, deny = one(app, "action.deny").frame
        let card = one(app, "chat.approval").frame
        XCTAssertLessThan(primary.maxY, deny.minY + tolerance, "stacked, primary first")
        XCTAssertEqual(primary.minX, deny.minX, accuracy: tolerance)
        XCTAssertEqual(primary.width, deny.width, accuracy: tolerance)
        let window = app.windows.firstMatch.frame
        for text in app.descendants(matching: .staticText).allElementsBoundByIndex where text.exists && text.frame.width > 0 {
            XCTAssertLessThanOrEqual(text.frame.maxX, window.maxX + tolerance, "\(text.label) leaves the screen")
        }
        for e in [primary, deny] { XCTAssertTrue(card.insetBy(dx: -tolerance, dy: -tolerance).contains(e) || e.maxY > window.maxY, "button outside the card") }
    }

    /// 10: what is meant to be round is a circle — |width − height| ≤ ½ pt — at the default size
    /// and at the largest accessibility size.
    func testRoundElementsAreCircles() {
        for ax in [false, true] {
            let app = launch(ax ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
            var ids = ["composer.attach", "toolbar.call"]
            ids.append(app.descendants(matching: .any)["composer.stop"].exists ? "composer.stop" : "composer.send")
            if !ax { ids.append("action.more") } // stacked at AX5: "More Answers", a full-width button
            ids.append("toolbar.pet")
            for id in ids {
                let f = one(app, id).frame
                XCTAssertEqual(f.width, f.height, accuracy: 0.5, "\(id) is an oval: \(f.size)\(ax ? " at AX5" : "")")
            }
            app.terminate()
        }
    }

    /// 1.4: a private sub-chat's name never reaches the screen outside the chat itself.
    func testPrivateChatNamesStayHidden() {
        let app = launch()
        let secret = "Taxes 2026"
        if UIDevice.current.userInterfaceIdiom == .phone {
            // The chats menu, from the title.
            let title = app.navigationBars.firstMatch.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Main chat")).firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            title.tap()
            XCTAssertTrue(app.buttons["Private chat"].waitForExistence(timeout: 5) || app.staticTexts["Private chat"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["Private chat"].waitForExistence(timeout: 5))
        }
        let labels = app.descendants(matching: .any).allElementsBoundByIndex.compactMap { $0.exists ? $0.label + " " + (($0.value as? String) ?? "") : nil }
        XCTAssertFalse(labels.contains { $0.contains(secret) }, "“\(secret)” is on screen")
    }
}
