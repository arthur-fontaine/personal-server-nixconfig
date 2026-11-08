import Foundation

/// The demo's content: a plausible week with Hermes. Used by the fake client and the tests.
public enum Fixtures {
    public static let threads: [ChatThread] = [
        ChatThread(id: 12, name: L("Home server"), iconColor: 0x8EEE98, iconEmoji: "🛠️", order: 3),
        ChatThread(id: 31, name: L("Taxes 2026"), iconColor: 0xFF93B2, iconEmoji: "🔐", order: 2),
        ChatThread(id: 44, name: L("Lisbon trip"), iconColor: 0xFFD67E, iconEmoji: "✈️", order: 1),
        ChatThread(id: 57, name: L("Reading list"), iconColor: 0xCB86DB, iconEmoji: "📚", order: 0),
        ChatThread(id: FakeTelegramClient.appTopic, name: AppProtocol.topicName),
    ]

    public static func messages(now: Date) -> [TopicID: [ChatMessage]] {
        func t(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        // Replies in both directions (design-rules 16.5), one to a deleted message.
        func me(_ id: MessageID, _ topic: TopicID, _ text: String, _ ago: Double, replyTo: MessageID? = nil) -> ChatMessage {
            ChatMessage(id: id, topic: topic, date: t(ago), isOutgoing: true, text: FormattedText(text), replyTo: replyTo)
        }
        func bot(_ id: MessageID, _ topic: TopicID, _ text: String, _ ago: Double, replyTo: MessageID? = nil) -> ChatMessage {
            ChatMessage(id: id, topic: topic, date: t(ago), isOutgoing: false, text: Markdownish.parse(text), replyTo: replyTo)
        }
        return [
            .main: [
                bot(1001, 0, L("Good morning! Three things overnight: the **nightly backup failed** at 03:12, Léa replied about Saturday, and your Lisbon flight is now boarding at gate 34 on Thursday."), 600),
                me(1002, 0, L("What happened with the backup?"), 590),
                bot(1003, 0, L("The external disk was full, so restic stopped before pruning:\n```\nFatal: unable to save snapshot: no space left on device\n```\nPruning snapshots older than 90 days would free about **212 GB**. Want me to do it?"), 588),
                me(1004, 0, L("Yes, go ahead"), 585, replyTo: 1003),
                approvalMessage(id: 1005, now: t(584)),
                me(1006, 0, L("Here's the video from Saturday for Léa"), 120, replyTo: 1001),
                ChatMessage(id: 1007, topic: 0, date: t(119), isOutgoing: true,
                            text: FormattedText(L("Too big for Telegram, so it went through Gofile.") + "\n[fichier: https://gofile.io/d/Qp9w8eR7]")),
                bot(1008, 0, L("Got it, I sent Léa the link with a note that it expires in 10 days."), 118),
                me(1009, 0, L("Remind me to call mum tonight"), 30),
                bot(1010, 0, L("Done: a reminder at 19:30 today, in Reminders on your iPhone."), 29, replyTo: 1009),
            ],
            12: [
                me(2001, 12, L("Can you check why the Hermes gateway restarted twice yesterday?"), 1500),
                bot(2002, 12, L("Both restarts were launchd bringing it back after a crash in the Telegram adapter, at 14:02 and 17:45. The second log line says `RetryAfter: 29`; it hit a flood limit while editing a long draft. I've opened a fix on a branch: `fix/telegram-flood-wait`."), 1495),
                bot(2003, 12, L("Merged: the fix is on main, and the gateway hasn't restarted since."), 600, replyTo: 1999),
            ],
            31: [
                bot(3001, 31, L("This sub-chat is encrypted. Your 2025 statements are in the vault; I've filled in the first two sections of the form."), 3000),
            ],
            44: [
                me(4001, 44, L("Find a quiet place to stay near Alfama, 3 nights from the 14th"), 4000),
                bot(4002, 44, L("Three options under €160 a night, all with good reviews for quiet:\n1. **Casa do Largo**: €142, terrace, 4 min from the tram\n2. **Alfama Patio**: €155, breakfast included\n3. **Memmo Alfama**: €159, pool, the most central\nShall I hold one?"), 3990),
            ],
            57: [
                bot(5001, 57, L("Saved: “The Pragmatic Programmer”, 20th anniversary edition."), 9000),
            ],
        ]
    }

    /// Hermes' reply caught mid-sentence, for the `review` scene.
    public static let reviewDraft = L("Found 41 snapshots older than 90 days, the oldest from 12 March. Deleting them needs your go-ahead: once pruned, restic can't bring")

    public static func approvalMessage(id: MessageID, now: Date) -> ChatMessage {
        let options = [(L("Once"), "ea:once:7"), (L("Session"), "ea:session:7"), (L("Always"), "ea:always:7"), (L("Deny"), "ea:deny:7")]
        return ChatMessage(
            id: id, topic: 0, date: now, isOutgoing: false,
            text: FormattedText("⚠️ " + L("Dangerous command: restic forget --keep-within 90d --prune")),
            buttons: options.enumerated().map { i, o in
                InlineButton(row: i < 3 ? 0 : 1, column: i < 3 ? i : 0, label: o.0, action: .callback(Data(o.1.utf8)))
            })
    }

    public static func approvalQuestion(messageID: MessageID) -> PendingQuestion {
        PendingQuestion(
            id: "ea:7", kind: .approval, chat: .main, messageID: messageID,
            text: L("Dangerous command: restic forget --keep-within 90d --prune"),
            spoken: L("Hermes asks to delete backups older than ninety days. Allow?"),
            summary: L("Delete backup snapshots older than 90 days to free about 212 GB on the external disk?"),
            command: "restic -r /Volumes/Backup/restic forget --keep-within 90d --prune",
            options: [
                QuestionOption(id: "once", label: L("Once"), data: Data("ea:once:7".utf8)),
                QuestionOption(id: "session", label: L("Session"), data: Data("ea:session:7".utf8)),
                QuestionOption(id: "always", label: L("Always"), data: Data("ea:always:7".utf8)),
                QuestionOption(id: "deny", label: L("Deny"), data: Data("ea:deny:7".utf8)),
            ], askedAt: .now)
    }

    public static func state(now: Date) -> AppState {
        AppState(
            agent: AgentState(status: .waitingUser, task: L("Waiting for your approval"), since: now.addingTimeInterval(-90), chat: .main),
            questions: [approvalQuestion(messageID: 1005)],
            pet: PetState(id: "pip", name: "Pip", version: 3,
                          spriteMessageID: 790,
                          manifest: PetManifest(id: "pip", displayName: "Pip", description: L("A small winged messenger.")),
                          mood: .waiting, animation: .waiting),
            subchats: [
                SubchatInfo(topicID: 31, name: L("Taxes 2026"), preset: "secret", encrypted: true, unlocked: false),
                SubchatInfo(topicID: 12, name: L("Home server"), preset: "project"),
                SubchatInfo(topicID: 44, name: L("Lisbon trip"), preset: "aside", ttl: "session"),
                SubchatInfo(topicID: 57, name: L("Reading list"), preset: "project"),
            ],
            slots: ["stats": 802, "devices": 801, "sprite": 790])
    }

    public static func appMessage(id: MessageID, json: String) -> ChatMessage {
        ChatMessage(id: id, topic: FakeTelegramClient.appTopic, date: .now, isOutgoing: false,
                    text: FormattedText(json, entities: [TextEntity(offset: 0, length: json.utf16.count, kind: .pre(language: "json"))]))
    }

    /// Serializes a state the way the backend does, so the fake goes through the real decoder.
    public static func stateJSON(_ s: AppState) -> String {
        var o: [String: Any] = ["v": AppProtocol.version, "type": "state"]
        if let a = s.agent {
            var agent: [String: Any] = ["status": a.status.rawValue, "chat": Int(a.chat ?? 0)]
            agent["task"] = a.task
            if let since = a.since { agent["since"] = since.timeIntervalSince1970 }
            o["agent"] = agent
        }
        o["questions"] = s.questions.map { q -> [String: Any] in
            var d: [String: Any] = ["id": q.id, "kind": q.kind.rawValue, "chat": Int(q.chat), "text": q.text,
                                    "options": q.options.map { ["id": $0.id, "label": $0.label, "data_b64": $0.data?.base64EncodedString() ?? ""] }]
            d["message_id"] = q.messageID
            d["summary"] = q.summary
            d["command"] = q.command
            d["spoken"] = q.spoken
            return d
        }
        if let p = s.pet {
            o["pet"] = ["id": p.id, "name": p.name, "version": p.version, "sprite_message_id": p.spriteMessageID ?? 0,
                        "manifest": ["id": p.id, "displayName": p.name, "spritesheetPath": "spritesheet.webp"],
                        "mood": (p.mood ?? .idle).rawValue, "animation": (p.animation?.rawValue).map { $0 as Any } ?? NSNull(),
                        "mood_until": p.moodUntil.map { $0.timeIntervalSince1970 as Any } ?? NSNull()]
        }
        o["subchats"] = s.subchats.map { ["topic_id": Int($0.topicID), "name": $0.name ?? "", "preset": $0.preset ?? NSNull(),
                                          "encrypted": $0.encrypted, "unlocked": $0.unlocked, "ttl": $0.ttl ?? NSNull()] }
        o["slots"] = s.slots
        let data = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static let statsJSON = """
    {"v":1,"type":"stats","updated_at":"2026-11-07T21:40:00Z",
     "machine":{"cpu_pct":12.5,"cores":10,"ram_used":17179869184,"ram_total":34359738368,
       "disk_used":401234567890,"disk_total":994662584320,"power_w":11.2,"energy_kwh_24h":0.27,
       "battery_pct":100,"charging":false,"on_ac":true,"temp_c":null,"uptime_s":432000,
       "history":{"cpu":[8,7,6,6,5,5,6,9,14,22,31,18,12,10,16,24,38,27,15,11,9,13,12,12.5],
                  "ram":[46,46,45,45,45,45,46,47,49,52,55,53,50,49,50,52,57,55,51,50,49,50,50,50],
                  "power":[8.1,7.9,7.6,7.5,7.4,7.4,7.8,8.9,10.4,12.8,15.6,11.9,10.1,9.6,10.9,13.1,17.2,14.4,10.8,9.9,9.4,10.6,10.9,11.2]}},
     "models":[
       {"provider":"opencode-go","model":"deepseek-v4.1-flash","role":"main","last_used":"2026-11-07T21:39:58Z",
        "windows":{"24h":{"calls":412,"tokens_in":2310000,"tokens_out":41000,"tokens_cached":1980000,"cost_usd":0.42,"errors":3},
                   "7d":{"calls":2630,"tokens_in":15100000,"tokens_out":286000,"tokens_cached":12900000,"cost_usd":2.71,"errors":11},
                   "30d":{"calls":10920,"tokens_in":61800000,"tokens_out":1190000,"tokens_cached":52300000,"cost_usd":11.04,"errors":37}}},
       {"provider":"openai-codex","model":"gpt-5.5","role":"fallback","last_used":"2026-11-07T18:02:11Z",
        "windows":{"24h":{"calls":9,"tokens_in":88000,"tokens_out":3100,"tokens_cached":41000,"cost_usd":null,"errors":0},
                   "7d":{"calls":71,"tokens_in":690000,"tokens_out":22000,"tokens_cached":350000,"cost_usd":null,"errors":1},
                   "30d":{"calls":240,"tokens_in":2400000,"tokens_out":81000,"tokens_cached":1200000,"cost_usd":null,"errors":2}}},
       {"provider":"baseten","model":"mammoth-1","role":"background","last_used":"2026-11-07T21:39:40Z",
        "windows":{"24h":{"calls":188,"tokens_in":402000,"tokens_out":9400,"tokens_cached":0,"cost_usd":0.06,"errors":0},
                   "7d":{"calls":1204,"tokens_in":2700000,"tokens_out":61000,"tokens_cached":0,"cost_usd":0.39,"errors":2},
                   "30d":{"calls":5010,"tokens_in":11200000,"tokens_out":250000,"tokens_cached":0,"cost_usd":1.62,"errors":5}}},
       {"provider":"uzu","model":"qwen3.5-9b","role":"local","last_used":"2026-11-07T20:11:00Z",
        "windows":{"24h":{"calls":57,"tokens_in":210000,"tokens_out":12000,"tokens_cached":0,"cost_usd":0,"errors":0},
                   "7d":{"calls":380,"tokens_in":1400000,"tokens_out":80000,"tokens_cached":0,"cost_usd":0,"errors":0},
                   "30d":{"calls":1490,"tokens_in":5600000,"tokens_out":310000,"tokens_cached":0,"cost_usd":0,"errors":1}}}
     ]}
    """

    public static let devicesJSON = """
    {"v":1,"type":"devices","updated_at":"2026-11-07T21:00:00Z","delivery":{"v":1,"team":{"id":"ABCDE12345","paid":false},
     "next_refresh":"2026-11-12T03:00:00Z",
     "devices":[{"id":"00008140-001A","name":"Arthur's iPhone","model":"iPhone18,1","os":"26.1","reachable":true,
                 "profile_expires":"2026-11-13T09:00:00Z","last_install":{"at":"2026-11-06T09:00:00Z","ok":true,"error":null,"version":"1.0","build":"42","pet_version":3}},
                {"id":"00008112-002B","name":"Arthur's iPad","model":"iPad16,3","os":"26.1","reachable":false,
                 "profile_expires":"2026-11-13T09:05:00Z","last_install":{"at":"2026-11-06T09:05:00Z","ok":true,"error":null,"version":"1.0","build":"42","pet_version":3}}]}}
    """

    public static func controlsJSON(mode: String, model: String, reasoning: String) -> String {
        """
        {"v":2,"type":"controls","updated_at":"2026-11-07T21:40:00Z",
         "permission_mode":{"value":"\(mode)","set":"/mode {value}","options":[
           {"id":"auto","label":"\(L("Auto"))","description":"\(L("Safe actions run; a reviewer judges the rest and blocks risky ones."))"},
           {"id":"ask","label":"\(L("Ask"))","description":"\(L("Every action but reads waits for your yes."))"}]},
         "model":{"chain":[{"provider":"opencode-go","model":"deepseek-v4.1-flash","role":"main"},
                           {"provider":"openai-codex","model":"gpt-5.5","role":"fallback"},
                           {"provider":"uzu","model":"qwen3.5-9b","role":"local"}],
                  "default":{"provider":"opencode-go","model":"deepseek-v4.1-flash","role":"main"},
                  "current":{"0":{"provider":"\(model == "gpt-5.5" ? "openai-codex" : "opencode-go")","model":"\(model)"}},
                  "last":{"0":{"provider":"opencode-go","model":"deepseek-v4.1-flash","at":"2026-11-07T21:39:58Z"}},
                  "set_main":"/model {model} --provider {provider}","set_subchat":"/sub set model {provider}:{model}"},
         "presets":[{"name":"aside","default":true,"memoryRead":true,"memoryWrite":false,"ttl":"session","encrypted":false,"model":null},
                    {"name":"project","memoryRead":true,"memoryWrite":false,"ttl":null,"encrypted":false,"model":null},
                    {"name":"secret","memoryRead":false,"memoryWrite":false,"ttl":null,"encrypted":true,"model":"uzu:local"},
                    {"name":"temp","memoryRead":false,"memoryWrite":false,"ttl":"1h","encrypted":false,"model":"uzu:local"}],
         "commands":[{"id":"stop","send":"/stop","where":"any"},{"id":"retry","send":"/retry","where":"any"},
           {"id":"undo","send":"/undo","where":"any","confirm":"\(L("Undo Hermes’ last turn?"))"},{"id":"btw","insert":"/btw ","where":"any"},
           {"id":"bg","insert":"/bg ","where":"any"},{"id":"goal","insert":"/goal ","where":"any"},
           {"id":"agents","send":"/agents","where":"any"},{"id":"status","send":"/status","where":"any"},
           {"id":"usage","send":"/usage","where":"any"},
           {"id":"reasoning","control":"picker","send":"/reasoning {value}","options":["low","medium","high"],"where":"any","value":"\(reasoning)"},
           {"id":"model","control":"model","where":"any"},{"id":"permissions","control":"permission_mode","where":"any"},
           {"id":"sub.new","control":"subchat_form","where":"main"},{"id":"sub.show","send":"/sub","where":"subchat"},
           {"id":"sub.set","insert":"/sub set ","where":"subchat"},{"id":"sub.lock","send":"/sub lock","where":"encrypted"},
           {"id":"sub.end","send":"/sub end","where":"subchat","confirm":"\(L("End this sub-chat? Its topic and memory are deleted."))"},
           {"id":"pause","send":"/pause","where":"any","confirm":"\(L("Stop all new work until you resume?"))"},
           {"id":"resume","send":"/pause off","where":"any"}]}
        """
    }

    static func answer(to text: String) -> String {
        let l = text.lowercased()
        if l.hasPrefix("/mode ") { return L("Permission mode: **\(String(text.dropFirst(6)))**.") }
        if l.hasPrefix("/model ") { return L("This chat now answers with **\(String(text.split(separator: " ")[1]))**.") }
        if l.hasPrefix("/sub new") {
            return L("Opened a new sub-chat. You’ll find it in the sidebar.")
        }
        if l.contains("weather") || l.contains("météo") {
            return L("Lisbon on Thursday: **21°C** and sunny, a light breeze off the river in the evening. Pack a thin jacket.")
        }
        return L("On it. I checked the server: CPU is at **12%**, memory at 50%, and the backup disk now has 212 GB free after last night’s prune. Nothing else needs you right now; I’ll ping you if the nightly run fails again.")
    }
}
