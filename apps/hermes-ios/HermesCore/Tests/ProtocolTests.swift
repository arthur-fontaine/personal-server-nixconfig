import Foundation
import Testing
@testable import HermesCore

@Suite("[fichier: url] links")
struct FileLinkTests {
    @Test func parsesOneLinkAtTheEnd() {
        let links = FileLink.parse("Here's the video\n[fichier: https://gofile.io/d/Qp9w8eR7]")
        #expect(links == [FileLink(url: URL(string: "https://gofile.io/d/Qp9w8eR7")!)])
        #expect(links[0].service == "Gofile")
    }

    @Test func parsesSeveralAndToleratesSpacingCaseAndBrackets() {
        let text = "two files\n[Fichier:https://a.example/x.zip]\n[ fichier : <https://swisstransfer.infomaniak.com/dl/abc-123> ]"
        let links = FileLink.parse(text)
        #expect(links.map(\.url.absoluteString) == ["https://a.example/x.zip", "https://swisstransfer.infomaniak.com/dl/abc-123"])
        #expect(links[1].service == "swisstransfer.infomaniak.com")
        #expect(links[0].displayName == "x.zip")
    }

    @Test func ignoresNonHTTPAndPlainBrackets() {
        #expect(FileLink.parse("[fichier: file:///etc/passwd] [note: hi] [fichier: ]").isEmpty)
    }

    @Test func stripsMarkersAndBlankLines() {
        #expect(FileLink.strip(from: "Video\n\n[fichier: https://gofile.io/d/x]\n") == "Video")
        #expect(FileLink.strip(from: "[fichier: https://gofile.io/d/x]") == "")
        #expect(FileLink.strip(from: "No links [here]") == "No links [here]")
    }

    @Test func appendsOneMarkerPerLine() {
        let urls = [FileLink(url: URL(string: "https://gofile.io/d/a")!), FileLink(url: URL(string: "https://gofile.io/d/b")!)]
        let text = FileLink.append(urls, to: "  hello  ")
        #expect(text == "hello\n[fichier: https://gofile.io/d/a]\n[fichier: https://gofile.io/d/b]")
        #expect(FileLink.parse(text) == urls)
        #expect(FileLink.append(urls, to: "").hasPrefix("[fichier:"))
    }

    @Test func messageDisplayTextHidesMarkers() {
        let m = ChatMessage(id: 1, topic: 0, date: .now, isOutgoing: true,
                            text: FormattedText("Too big\n[fichier: https://gofile.io/d/Qp9w8eR7]"))
        #expect(m.displayText == "Too big")
        #expect(m.fileLinks.count == 1)
    }
}

@Suite("App topic envelope")
struct EnvelopeTests {
    @Test func extractsFromFenceOrBareObject() throws {
        let fenced = "```json\n{\"v\":1,\"type\":\"ack\"}\n```"
        #expect(String(decoding: try #require(AppProtocol.extractJSON(from: fenced)), as: UTF8.self) == "{\"v\":1,\"type\":\"ack\"}")
        // Bot → app: the JSON is the plain text, the <pre> being an entity.
        #expect(AppProtocol.extractJSON(from: " {\"v\":1} ") != nil)
        #expect(AppProtocol.extractJSON(from: "hello") == nil)
        #expect(AppProtocol.extractJSON(from: "```json\n{\"unterminated\": 1}") == nil)
    }

    @Test func encodesRequestsAsFencedJSON() throws {
        let text = AppProtocol.encode(.petFeed)
        #expect(text.hasPrefix("```json\n") && text.hasSuffix("\n```"))
        let obj = try JSONSerialization.jsonObject(with: try #require(AppProtocol.extractJSON(from: text))) as? [String: Any]
        #expect(obj?["type"] as? String == "pet.feed")
        #expect(obj?["v"] as? Int == 2)
    }

    @Test func encodesAckAndPushRegister() throws {
        let ack = try JSONSerialization.jsonObject(with: AppProtocol.extractJSON(from: AppProtocol.encode(.ack([5, 6])))!) as! [String: Any]
        #expect(ack["ids"] as? [Int] == [5, 6])
        let push = AppProtocol.encode(.pushRegister(token: Data([0xAB, 0x01]), kind: "alert", sandbox: true, bundleID: "x.app"))
        #expect(push.contains("\"token_hex\":\"ab01\""))
    }

    @Test func unknownTypesAreOther() {
        guard case .other(let type, _)? = AppProtocol.decode("{\"v\":1,\"type\":\"future.thing\"}") else {
            Issue.record("expected .other"); return
        }
        #expect(type == "future.thing")
        #expect(AppProtocol.decode("{\"v\":1}") == nil)
    }
}

@Suite("state slot")
struct StateTests {
    // The example of app-protocol.md §2.1, verbatim.
    static let example = """
    {
      "v": 1, "type": "state", "updated_at": "2026-11-07T21:40:03Z",
      "slots": {"stats": 812, "devices": 813, "sprite": 790},
      "agent": {
        "status": "working", "chat": 0, "task": "Running: nix build …",
        "progress": "3 tool calls", "since": "2026-11-07T21:39:51Z",
        "busy_chats": [0, 455]
      },
      "questions": [
        {
          "id": "ea:7", "kind": "approval", "chat": 0, "message_id": 1201,
          "text": "Dangerous command: rm -rf ~/tmp/build",
          "summary": "Delete the build folder in your temp directory",
          "command": "rm -rf ~/tmp/build",
          "spoken": "Hermes asks to delete the build folder in your temp directory. Allow?",
          "options": [
            {"id": "once", "label": "Once", "data_b64": "ZWE6b25jZTo3"},
            {"id": "session", "label": "Session", "data_b64": "ZWE6c2Vzc2lvbjo3"},
            {"id": "always", "label": "Always", "data_b64": "ZWE6YWx3YXlzOjc="},
            {"id": "deny", "label": "Deny", "data_b64": "ZWE6ZGVueTo3"}
          ],
          "asked_at": "2026-11-07T21:40:01Z"
        }
      ],
      "pet": {
        "id": "pip", "name": "Pip", "version": 3,
        "manifest": {"id": "pip", "displayName": "Pip", "description": "…",
                     "spritesheetPath": "spritesheet.webp", "version": 3},
        "sprite_message_id": 790,
        "animation": "run",
        "mood": "focused", "hunger": 35, "energy": 70, "happiness": 82,
        "xp": 1240, "level": 6, "xp_next": 1500, "asleep": false,
        "updated_at": "2026-11-07T21:39:51Z"
      },
      "subchats": [
        {"topic_id": 455, "name": "Taxes", "preset": "secret", "encrypted": true,
         "unlocked": false, "ttl": null, "expires_at": null}
      ]
    }
    """

    func decodeState(_ text: String) throws -> AppState {
        guard case .state(let s)? = AppProtocol.decode(text) else { throw CancellationError() }
        return s
    }

    @Test func decodesTheProtocolExample() throws {
        let s = try decodeState(Self.example)
        #expect(s.agent?.status == .working)
        #expect(s.agent?.busyChats == [0, 455])
        #expect(s.agent?.since == ISO8601DateFormatter().date(from: "2026-11-07T21:39:51Z"))
        #expect(s.slots == ["stats": 812, "devices": 813, "sprite": 790])
        let q = try #require(s.question)
        #expect(q.kind == .approval)
        #expect(q.messageID == 1201)
        #expect(q.summary == "Delete the build folder in your temp directory")
        #expect(q.options.map(\.label) == ["Once", "Session", "Always", "Deny"])
        #expect(q.options[0].data == Data("ea:once:7".utf8))
        #expect(q.options[3].isDestructive && !q.options[0].isDestructive)
        let pet = try #require(s.pet)
        #expect(pet.hunger == 0.35 && pet.happiness == 0.82)
        #expect(pet.animation == .running)
        #expect(pet.spriteMessageID == 790)
        #expect(pet.manifest?.displayName == "Pip")
        #expect(s.subchats == [SubchatInfo(topicID: 455, name: "Taxes", preset: "secret", encrypted: true)])
    }

    @Test func oneBadSectionDoesNotDropTheRest() throws {
        let s = try decodeState("""
        {"v":1,"type":"state","agent":{"status":"thinking"},"pet":"not an object",
         "questions":[{"id":"x","options":"nope"},{"id":"y","text":"ok","options":[]}],"subchats":[{"name":"no id"}]}
        """)
        #expect(s.agent?.status == .thinking)
        #expect(s.pet == nil)
        #expect(s.questions.map(\.id) == ["x", "y"])
        #expect(s.subchats.isEmpty)
    }

    @Test func unknownStatusAndLegacySingleQuestion() throws {
        let s = try decodeState(#"{"v":1,"type":"state","agent":{"status":"dreaming"},"question":{"id":"q","text":"?","command":"ls"}}"#)
        #expect(s.agent?.status == .idle)
        #expect(s.questions.first?.kind == .approval)
    }

    @Test func gaugesAcceptFractionsAndPercent() throws {
        let s = try decodeState(#"{"v":1,"type":"state","pet":{"hunger":0.5,"energy":100,"happiness":-3}}"#)
        #expect(s.pet?.hunger == 0.5)
        #expect(s.pet?.energy == 1)
        #expect(s.pet?.happiness == 0)
    }
}

@Suite("stats, devices, notify, reply")
struct OtherSlotsTests {
    @Test func decodesStats() throws {
        guard case .stats(let s)? = AppProtocol.decode(Fixtures.statsJSON) else { Issue.record("no stats"); return }
        #expect(s.models.count == 4)
        let main = try #require(s.models.first { $0.role == .main })
        #expect(main.figures(.day).calls == 412)
        #expect(main.figures(.week).costUSD == 2.71)
        #expect(abs(main.figures(.day).cacheRatio - 0.857) < 0.01)
        // cost_usd null (subscription) → 0, not a failure.
        #expect(s.models.first { $0.role == .fallback }?.figures(.day).costUSD == 0)
        let m = try #require(s.machine)
        #expect(m.cpuHistory.count == 24)
        #expect(m.ramFraction == 0.5)
        #expect(m.temperatureC == nil)
    }

    @Test func flatModelWindowIsAccepted() throws {
        let text = #"{"v":1,"type":"stats","models":[{"provider":"p","model":"m","window":"7d","calls":3}, {"bad":1}]}"#
        guard case .stats(let s)? = AppProtocol.decode(text) else { Issue.record("no stats"); return }
        #expect(s.models.count == 1)
        #expect(s.models[0].figures(.week).calls == 3)
        #expect(s.models[0].role == .other)
    }

    @Test func decodesDevices() throws {
        guard case .devices(let d)? = AppProtocol.decode(Fixtures.devicesJSON) else { Issue.record("no devices"); return }
        #expect(d.teamPaid == false)
        #expect(d.devices.map(\.name) == ["Arthur's iPhone", "Arthur's iPad"])
        #expect(d.devices[0].build == "1.0 (42)")
        #expect(d.devices[0].profileExpiry != nil)
        #expect(d.devices[1].reachable == false)
        guard case .devices(let empty)? = AppProtocol.decode(#"{"v":1,"type":"devices","delivery":null}"#) else { return }
        #expect(empty.devices.isEmpty)
    }

    @Test func decodesNotify() throws {
        let text = #"{"v": 1, "type": "notify", "chat": 0, "message_id": 1187, "kind": "message", "interruption": "active", "title": "Hermes", "body": "The build passed. 3 warnings in the …", "spoken": "The build passed, with three warnings."}"#
        guard case .notify(let n)? = AppProtocol.decode(text) else { Issue.record("no notify"); return }
        #expect(n.messageID == 1187)
        #expect(n.speechText == "The build passed, with three warnings.")
        #expect(n.interruption == .active)
        guard case .notify(let q)? = AppProtocol.decode(#"{"v":1,"type":"notify","chat":455,"body":"Allow?","interruption":"time-sensitive"}"#) else { return }
        #expect(q.interruption == .timeSensitive && q.chat == 455 && q.speechText == "Allow?")
    }

    @Test func decodesRepliesAndCallState() throws {
        guard case .reply(let ok)? = AppProtocol.decode(#"{"v":2,"type":"reply","re":1302,"ok":true,"data":{"active":true}}"#) else {
            Issue.record("no reply"); return
        }
        #expect(ok.re == 1302 && ok.ok)
        let req = AppProtocol.encode(.callState(active: true))
        #expect(req.contains("\"type\":\"call.state\"") && req.contains("\"active\":true"))
        #expect(CallTurn.message(for: " what's next? ") == "🎙 what's next?")
        #expect(CallTurn.isCallTurn("🎙 hi") && !CallTurn.isCallTurn("hi 🎙"))
        guard case .reply(let bad)? = AppProtocol.decode(#"{"v":1,"type":"reply","re":1303,"ok":false,"error":{"code":"busy","message":"A pet is already being generated"}}"#) else { return }
        #expect(!bad.ok && bad.errorCode == "busy")
    }
}

@Suite("controls slot")
struct ControlsTests {
    func decode() throws -> ControlsState {
        guard case .controls(let c)? = AppProtocol.decode(Fixtures.controlsJSON(mode: "auto", model: "deepseek-v4.1-flash", reasoning: "medium")) else {
            throw CancellationError()
        }
        return c
    }

    @Test func decodesTheSlot() throws {
        let c = try decode()
        #expect(c.permissionMode?.options.map(\.id) == ["auto", "ask"])
        #expect(c.permissionMode?.command(for: "ask") == "/mode ask")
        #expect(c.model?.chain.count == 3)
        #expect(c.model?.selected(in: .main)?.model == "deepseek-v4.1-flash")
        #expect(c.model?.selected(in: 12)?.model == "deepseek-v4.1-flash")
        #expect(c.model?.last[.main]?.at != nil)
        #expect(c.orderedPresets.first?.name == "aside")
        #expect(c.presets.first { $0.name == "secret" }?.summary == "Encrypted, no main memory, model uzu:local")
        #expect(c.commands.count == 19)
        #expect(c.commands.first { $0.id == "reasoning" }?.options == ["low", "medium", "high"])
    }

    @Test func filtersCommandsByChat() throws {
        let c = try decode()
        let main = c.commands(for: CommandContext(topic: .main)).map(\.id)
        #expect(main.contains("sub.new") && !main.contains("sub.end") && !main.contains("sub.lock"))
        #expect(main.first == "model")
        let sub = c.commands(for: CommandContext(topic: 12)).map(\.id)
        #expect(!sub.contains("sub.new") && sub.contains("sub.end") && !sub.contains("sub.lock"))
        let secret = c.commands(for: CommandContext(topic: 31, isEncrypted: true, isUnlocked: true)).map(\.id)
        #expect(secret.contains("sub.lock"))
    }

    @Test func fillsTemplates() throws {
        let c = try decode()
        let r = try #require(c.commands.first { $0.id == "reasoning" })
        #expect(r.text(["value": "high"]) == "/reasoning high")
        #expect(c.commands.first { $0.id == "btw" }?.insert == "/btw ")
        #expect(CommandCatalog.entry("sub.end").label == "End sub-chat")
        #expect(CommandCatalog.entry("unknown").label == "unknown")
    }

    @Test func permissionsHiddenWhenNotReported() {
        let c = ControlsState(permissionMode: nil, commands: [CommandSpec(id: "permissions", control: "permission_mode"), CommandSpec(id: "stop", send: "/stop")])
        #expect(c.commands(for: CommandContext(topic: .main)).map(\.id) == ["stop"])
    }
}
