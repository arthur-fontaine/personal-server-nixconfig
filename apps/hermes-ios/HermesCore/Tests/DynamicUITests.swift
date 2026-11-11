import Foundation
import Testing
import UIKit
@testable import HermesCore

/// Dynamic UI (docs/app-protocol.md §8): json-render specs as `render_ui` sends them.
@Suite("Dynamic UI: decoding and resolving specs")
struct DynamicUIResolveTests {
    func spec(_ json: String) -> UISpec { UISpec.decode(Data(json.utf8))! }
    func resolve(_ json: String) -> UINode? { let s = spec(json); return DynamicUI.resolve(s, state: s.state) }

    @Test func weather() throws {
        let s = Fixtures.spec(Fixtures.weatherSpec)
        let root = try #require(DynamicUI.resolve(s, state: s.state))
        guard case .card(let title, _) = root.kind else { Issue.record("not a card"); return }
        #expect(title == "Lisbon, Thursday")
        #expect(root.children.map(\.key) == ["now", "details", "chart", "actions"])
        let now = root.children[0]
        #expect(now.kind == .stack(axis: .horizontal, gap: .medium, align: .center, justify: .start))
        #expect(now.children[0].kind == .icon(name: "Sun", symbol: "sun.max.fill", size: .large, color: .default))
        // A number where a string goes: 21, not "21.0".
        guard case .metric(let m) = now.children[1].kind else { Issue.record("not a metric"); return }
        #expect(m.value == "21 °C" && m.changeType == .positive)
        // `data: {"$state": "/forecast"}` reads the state.
        guard case .lineGraph(_, let data) = root.children[2].kind else { Issue.record("not a chart"); return }
        #expect(data.map(\.value) == [21, 23, 24, 20, 19] && data.first?.label == "Thu")
        guard case .grid(let columns, _) = root.children[1].kind else { Issue.record("not a grid"); return }
        #expect(columns == 3)
    }

    @Test func table() {
        let root = resolve(#"""
        {"root":"t","elements":{"t":{"type":"Table","props":{"columns":["Disk","Used"],
          "rows":[["SSD", 41],{"Disk":"Backup","Used":"87 %"},"junk"],"caption":"Today"}}}}
        """#)
        #expect(root?.kind == .table(columns: ["Disk", "Used"], rows: [["SSD", "41"], ["Backup", "87 %"]], caption: "Today"))
    }

    @Test func repeatWithItemIndexAndTemplate() {
        let root = resolve(#"""
        {"root":"list","state":{"todos":[{"title":"Milk","done":true},{"title":"Eggs","done":false}],"who":"Arthur"},
         "elements":{
          "list":{"type":"Stack","repeat":{"statePath":"/todos"},"children":["row"]},
          "row":{"type":"Text","props":{"text":{"$template":"${who}: ${title} (#${/todos/0/title})"}},
                 "visible":{"$item":"done","not":true}},
          "idx":{"type":"Text","props":{"text":{"$index":true}}}}}
        """#)
        // One child per item, hidden where the item is done; ids unique per item.
        #expect(root?.children.count == 1)
        #expect(root?.children.first?.kind == .text("Arthur: Eggs (#Milk)", variant: .body))
        #expect(root?.children.first?.id == "row@/todos/1")
        let indexed = resolve(#"""
        {"root":"l","state":{"xs":["a","b","c"]},"elements":{"l":{"type":"Stack","repeat":{"statePath":"/xs"},"children":["i"]},
         "i":{"type":"Badge","props":{"text":{"$index":true}}}}}
        """#)
        #expect(indexed?.children.map(\.kind) == [.badge("0", variant: .default), .badge("1", variant: .default), .badge("2", variant: .default)])
    }

    @Test func condAndVisibility() {
        let json = #"""
        {"root":"s","state":{"temp":31,"user":{"admin":true},"mode":"dark","n":0},"elements":{
         "s":{"type":"Stack","children":["hot","admin","mode","neither","either","list","op","zero"]},
         "hot":{"type":"Text","props":{"text":{"$cond":{"$state":"/temp","gt":30},"$then":"Hot","$else":"Mild"}}},
         "admin":{"type":"Text","props":{"text":"A"},"visible":{"$state":"/user/admin"}},
         "mode":{"type":"Text","props":{"text":"M"},"visible":{"$state":"/mode","neq":"dark"}},
         "neither":{"type":"Text","props":{"text":"N"},"visible":{"$and":[{"$state":"/user/admin"},{"$state":"/temp","lt":20}]}},
         "either":{"type":"Text","props":{"text":"E"},"visible":{"or":[{"$state":"/mode","eq":"light"},{"$state":"/temp","gte":31}]}},
         "list":{"type":"Text","props":{"text":"L"},"visible":[{"$state":"/user/admin"},{"$state":"/missing","not":true}]},
         "op":{"type":"Text","props":{"text":"O"},"visible":{"eq":[{"$state":"/mode"},"dark"]}},
         "zero":{"type":"Text","props":{"text":"Z"},"visible":{"$state":"/n"}}}}
        """#
        let texts = resolve(json)?.children.compactMap { n -> String? in if case .text(let t, _) = n.kind { t } else { nil } }
        #expect(texts == ["Hot", "A", "E", "L", "O"])
    }

    @Test func unknownTypeDrawsNothingAndKeepsSiblings() {
        let root = resolve(#"{"root":"c","elements":{"c":{"type":"Card","children":["x","t"]},"x":{"type":"Marquee","props":{"speed":9}},"t":{"type":"Text","props":{"text":"ok"}}}}"#)
        #expect(root?.children.map(\.kind) == [.unknown("Marquee"), .text("ok", variant: .body)])
    }

    @Test func cyclesAndMissingChildrenAreCut() {
        let root = resolve(#"{"root":"a","elements":{"a":{"type":"Card","children":["b","ghost"]},"b":{"type":"Stack","children":["a","c"]},"c":{"type":"Text","props":{"text":"leaf"}}}}"#)
        #expect(root?.children.count == 1)
        #expect(root?.children.first?.children.map(\.key) == ["c"])
    }

    @Test func badSpecsShowTheText() {
        #expect(UISpec.decode(Data(#"{"elements":{}}"#.utf8)) == nil)
        #expect(UISpec.decode(Data("[1,2]".utf8)) == nil)
        // A root that isn't an element: decodes, but nothing to draw.
        let s = spec(#"{"root":"nope","elements":{"a":{"type":"Text"}}}"#)
        #expect(!s.isRenderable)
        #expect(Fixtures.spec(Fixtures.hotelsSpec).isRenderable)
    }

    @Test func lenientProps() {
        let root = resolve(#"""
        {"root":"s","elements":{"s":{"type":"Stack","props":{"gap":7,"direction":true},"children":["p","g","b","m"]},
         "p":{"type":"Progress","props":{"value":"150","label":3}},
         "g":{"type":"Grid","props":{"columns":"40"}},
         "b":{"type":"Button","props":{"label":"Go","variant":"loud","disabled":"true"}},
         "m":{"type":"Metric","props":{"label":"Δ","value":-2.5,"change":"-0.4"}}}}
        """#)
        #expect(root?.kind == .stack(axis: .vertical, gap: .medium, align: .start, justify: .start))
        #expect(root?.children.map(\.kind) == [
            .progress(fraction: 1, label: "3"), .grid(columns: 6, gap: .medium),
            .button(label: "Go", variant: .secondary, disabled: true),
            .metric(UIMetric(label: "Δ", value: "-2.5", change: "-0.4", changeType: .negative)),
        ])
    }

    @Test func tabsShowOnePanelPerTab() throws {
        let s = Fixtures.spec(Fixtures.catalogueSpec)
        let tabs = try #require(DynamicUI.resolve(s, state: s.state)?.children.first)
        #expect(tabs.kind == .tabs(options: [UIOption(label: "Usage", value: "usage"), UIOption(label: "Disks", value: "disks")], selected: "usage"))
        #expect(tabs.children.map(\.key) == ["usage"])
        #expect(tabs.valuePath == "/tab")
        let other = DynamicUI.resolve(s, state: JSONPointer.set(s.state, "/tab", .string("disks")))?.children.first
        #expect(other?.children.map(\.key) == ["disks"])
        // The disks panel repeats a Progress per disk, its label and value from the item.
        #expect(other?.children.first?.children.map(\.kind) == [.progress(fraction: 0.41, label: "Macintosh HD"), .progress(fraction: 0.87, label: "Backup")])
    }

    @Test func actions() throws {
        let s = Fixtures.spec(Fixtures.hotelsSpec)
        var state = s.state
        let root = try #require(DynamicUI.resolve(s, state: state))
        let pick = try #require(root.children.first { $0.key == "pick" })
        #expect(pick.valuePath == "/hotel")
        guard case .buttonGroup(_, let selected) = pick.kind else { Issue.record("no group"); return }
        #expect(selected == "Casa do Largo")
        // Choosing writes the bound state; the templated reply reads it.
        state = JSONPointer.set(state, pick.valuePath!, .string("Memmo Alfama"))
        let hold = try #require(DynamicUI.resolve(s, state: state)?.children.first { $0.key == "hold" })
        #expect(hold.kind == .button(label: "Hold Memmo Alfama", variant: .primary, disabled: false))
        #expect(DynamicUI.actions("press", of: hold, state: state) == [.reply("Hold Memmo Alfama for 3 nights from the 14th")])
        // No selection: the button is hidden.
        #expect(DynamicUI.resolve(s, state: .object([:]))?.children.contains { $0.key == "hold" } == false)

        let w = Fixtures.spec(Fixtures.weatherSpec)
        let buttons = try #require(DynamicUI.resolve(w, state: w.state)?.children.last?.children)
        #expect(DynamicUI.actions("press", of: buttons[1], state: w.state) == [.reply("Show me Thursday hour by hour")])
        #expect(DynamicUI.actions("press", of: buttons[0], state: w.state) == [.open(URL(string: "https://www.ipma.pt/en/otempo/prev.localidade.hora/")!)])
    }

    @Test func actionEdgeCases() throws {
        let s = spec(#"""
        {"root":"l","state":{"items":[{"n":"a"},{"n":"b"}]},"elements":{
         "l":{"type":"Stack","repeat":{"statePath":"/items"},"children":["b"]},
         "b":{"type":"Button","props":{"label":{"$item":"n"}},"on":{"press":[
           {"action":"setState","params":{"statePath":{"$item":"done"},"value":true}},
           {"action":"open","params":{"url":"javascript:alert(1)"}},
           {"action":"navigate","params":{"to":"/x"}}]}},
         "g":{"type":"ButtonGroup","props":{"buttons":["Yes","No"]},"on":{"press":{"action":"reply"}}}}}
        """#)
        let second = try #require(DynamicUI.resolve(s, state: s.state)?.children.last)
        #expect(DynamicUI.actions("press", of: second, state: s.state) == [
            .setState(path: "/items/1/done", value: .bool(true)), .unknown("open without an http(s) url"), .unknown("navigate"),
        ])
        // A choice that replies without text replies with its label; "press" serves "change".
        let g = spec(#"{"root":"g","elements":{"g":{"type":"ButtonGroup","props":{"buttons":["Yes","No"]},"on":{"press":{"action":"reply"}}}}}"#)
        let group = try #require(DynamicUI.resolve(g, state: g.state))
        #expect(group.valuePath != nil)
        #expect(DynamicUI.actions("change", of: group, state: g.state, choice: UIOption(label: "No", value: "No")) == [.reply("No")])
    }

    @Test func jsonPointer() {
        let v = JSONValue.object(["a/b": .array([.number(1)]), "m~n": .string("x")])
        #expect(JSONPointer.get(v, "/a~1b/0") == .number(1))
        #expect(JSONPointer.get(v, "/m~0n") == .string("x"))
        #expect(JSONPointer.get(v, "/a~1b/5") == nil)
        #expect(JSONPointer.get(v, "") == v)
        let set = JSONPointer.set(.object([:]), "/form/tags/0", .string("t"))
        #expect(JSONPointer.get(set, "/form/tags/0") == .string("t"))
        #expect(JSONPointer.set(.object(["l": .array([.number(1)])]), "/l/-", .number(2)) == .object(["l": .array([.number(1), .number(2)])]))
    }

    @Test func everyMappedSymbolExists() {
        let missing = LucideSymbols.table.values.filter { UIImage(systemName: $0) == nil } + (UIImage(systemName: LucideSymbols.fallback) == nil ? [LucideSymbols.fallback] : [])
        #expect(missing.isEmpty, "\(missing)")
        #expect(LucideSymbols.symbol(for: "cloud-rain") == "cloud.rain" && LucideSymbols.symbol(for: "Wibble") == LucideSymbols.fallback)
        #expect(LucideSymbols.spoken("AlertTriangle") == "alert triangle" && LucideSymbols.spoken("map-pin") == "map pin")
    }

    @Test func protocolMessage() {
        guard case .ui(let e)? = AppProtocol.decode(Fixtures.uiJSON(chat: 44, messageID: 4004, spec: Fixtures.weatherSpec)) else {
            Issue.record("no ui"); return
        }
        #expect(e.chat == 44 && e.messageID == 4004 && !e.isFile && e.spec == Fixtures.spec(Fixtures.weatherSpec))
        guard case .ui(let f)? = AppProtocol.decode(#"{"v":4,"type":"ui","chat":0,"message_id":12,"file":true}"#) else {
            Issue.record("no file ui"); return
        }
        #expect(f.isFile && f.spec == nil)
        #expect(AppProtocol.decode(#"{"v":4,"type":"ui","chat":0,"message_id":12}"#) == nil)
    }
}

@MainActor
@Suite("Dynamic UI in the store")
struct DynamicUIStoreTests {
    let chat = FakeTelegramClient.botChat.chatID

    func makeStore(memory: URL? = nil) async throws -> (HermesStore, FakeTelegramClient) {
        let client = FakeTelegramClient()
        client.streamDelay = .milliseconds(1)
        let store = HermesStore(client: client, config: .preview)
        store.uiMemory = UISpecMemory(directory: memory)
        store.start()
        try await waitUntil { store.isReady && store.state.pet != nil }
        return (store, client)
    }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func message(_ id: MessageID, topic: TopicID = .main) -> ChatMessage {
        ChatMessage(id: Fixtures.id(id), topic: topic, date: .now, isOutgoing: false, text: FormattedText("Météo Paris : 14 °C"))
    }

    @Test func theDemoShowsItsUIs() async throws {
        let (store, _) = try await makeStore()
        try await waitUntil { store.uiSpecs.count == 2 }
        await store.loadHistory(44)
        let weather = try #require(store.messages(in: 44).first { $0.id == Fixtures.id(4004) })
        #expect(store.uiSpec(for: weather) == Fixtures.spec(Fixtures.weatherSpec))
    }

    @Test func beforeOrAfterItsMessage() async throws {
        let (store, _) = try await makeStore()
        // The UI first, then its message.
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 910, json: Fixtures.uiJSON(chat: 0, messageID: 2000, spec: Fixtures.weatherSpec))))
        store._apply(.newMessage(chat, message(2000)))
        #expect(store.uiSpec(for: message(2000)) != nil)
        // The message first, then its UI.
        store._apply(.newMessage(chat, message(2001)))
        #expect(store.uiSpec(for: message(2001)) == nil)
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 911, json: Fixtures.uiJSON(chat: 0, messageID: 2001, spec: Fixtures.hotelsSpec))))
        #expect(store.uiSpec(for: message(2001)) == Fixtures.spec(Fixtures.hotelsSpec))
        // The newest wins; an older one replayed from history doesn't.
        store._apply(.newMessage(chat, Fixtures.appMessage(id: 905, json: Fixtures.uiJSON(chat: 0, messageID: 2001, spec: Fixtures.weatherSpec))))
        #expect(store.uiSpec(for: message(2001)) == Fixtures.spec(Fixtures.hotelsSpec))
        // Never on the owner's own message.
        var mine = message(2001)
        mine.isOutgoing = true
        #expect(store.uiSpec(for: mine) == nil)
    }

    @Test func aBigSpecComesAsADocument() async throws {
        let (store, client) = try await makeStore()
        let file = FileManager.default.temporaryDirectory.appending(path: "ui-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: Fixtures.catalogueSpec).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        client.files[4242] = file
        let caption = #"{"v":4,"type":"ui","chat":0,"message_id":2002,"file":true}"#
        var doc = Fixtures.appMessage(id: 912, json: caption)
        doc.attachment = FileAttachment(kind: .document, fileID: 4242, name: "ui.json", mimeType: "application/json", size: 9000)
        store._apply(.newMessage(chat, doc))
        try await waitUntil { store.uiSpec(for: message(2002)) != nil }
        #expect(store.uiSpec(for: message(2002)) == Fixtures.spec(Fixtures.catalogueSpec))
        #expect(store.topicLog.lastError == nil)
    }

    @Test func keptAcrossLaunches() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ui-memory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let (store, _) = try await makeStore(memory: dir)
            store._apply(.newMessage(chat, Fixtures.appMessage(id: 913, json: Fixtures.uiJSON(chat: 0, messageID: 2003, spec: Fixtures.hotelsSpec))))
        }
        let again = HermesStore(client: FakeTelegramClient(), config: .preview)
        again.uiMemory = UISpecMemory(directory: dir)
        again._loadUIMemory()
        #expect(again.uiSpec(for: message(2003)) == Fixtures.spec(Fixtures.hotelsSpec))
    }

    @Test func aReplyAnswersTheUIsMessage() async throws {
        let (store, client) = try await makeStore()
        await store.loadHistory(44)
        let weather = try #require(store.messages(in: 44).first { $0.id == Fixtures.id(4004) })
        try await store.reply("Show me Thursday hour by hour", to: weather)
        #expect(client.sent.last == "Show me Thursday hour by hour")
        #expect(client.repliedTo.last == weather.id)
        #expect(store.messages(in: 44).last?.replyTo == weather.id)
    }
}
