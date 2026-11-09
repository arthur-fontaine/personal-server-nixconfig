import Foundation
import Testing
@testable import HermesCore

/// A guard card reads whole from its message, before the state's question arrives.
@Suite("Approval card text")
struct ApprovalTextTests {
    static func card(label: String) -> FormattedText {
        let header = "⚠️ Hermes wants to run a command that needs your OK\n\n"
        let box = "<terminal> (plugin approval rule)"
        let rest = "\n\n\(label): Hermes veut créer un petit fichier. Le mode auto demande.\n\nterminal: echo hi > /tmp/x && rm -f /tmp/x...\n\nIf you don't answer within 5 minutes it will NOT run."
        let text = header + box + rest
        return FormattedText(text, entities: [
            TextEntity(offset: 0, length: header.utf16.count - 2, kind: .bold),
            TextEntity(offset: header.utf16.count, length: box.utf16.count, kind: .pre(language: nil)),
        ])
    }

    @Test(arguments: ["Why it was flagged", "Raison"])
    func theSentenceAndActionComeFromTheMessage(label: String) throws {
        let parsed = try #require(ApprovalText.parse(Self.card(label: label)))
        #expect(parsed.sentence == "Hermes veut créer un petit fichier. Le mode auto demande.")
        #expect(parsed.action == "terminal: echo hi > /tmp/x && rm -f /tmp/x...")
    }

    @Test func otherMessagesAreNotCards() {
        #expect(ApprovalText.parse(FormattedText("Hello")) == nil)
        let code = "ls -la"
        #expect(ApprovalText.parse(FormattedText("x\n\n\(code)\n\nReason: y\n\nz",
                                                 entities: [TextEntity(offset: 3, length: code.utf16.count, kind: .pre(language: nil))])) == nil)
    }
}
