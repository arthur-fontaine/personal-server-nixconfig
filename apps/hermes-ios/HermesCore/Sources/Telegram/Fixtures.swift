import Foundation

/// The demo's content: a plausible week with Hermes. Used by the fake client and the tests.
public enum Fixtures {
    public static let threads: [ChatThread] = [
        ChatThread(id: 12, name: "Home server", iconColor: 0x8EEE98, iconEmoji: "🛠️", order: 3),
        ChatThread(id: 31, name: "Taxes 2026", iconColor: 0xFF93B2, iconEmoji: "🔐", order: 2),
        ChatThread(id: 44, name: "Lisbon trip", iconColor: 0xFFD67E, iconEmoji: "✈️", order: 1),
        ChatThread(id: 57, name: "Reading list", iconColor: 0xCB86DB, iconEmoji: "📚", order: 0),
        ChatThread(id: FakeTelegramClient.appTopic, name: AppProtocol.topicName),
    ]

    public static func messages(now: Date) -> [TopicID: [ChatMessage]] {
        func t(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        func me(_ id: MessageID, _ topic: TopicID, _ text: String, _ ago: Double) -> ChatMessage {
            ChatMessage(id: id, topic: topic, date: t(ago), isOutgoing: true, text: FormattedText(text))
        }
        func bot(_ id: MessageID, _ topic: TopicID, _ text: String, _ ago: Double) -> ChatMessage {
            ChatMessage(id: id, topic: topic, date: t(ago), isOutgoing: false, text: Markdownish.parse(text))
        }
        return [
            .main: [
                bot(1001, 0, "Good morning! Three things overnight: the **nightly backup failed** at 03:12, Léa replied about Saturday, and your Lisbon flight is now boarding at gate 34 on Thursday.", 600),
                me(1002, 0, "What happened with the backup?", 590),
                bot(1003, 0, "The external disk was full, so restic stopped before pruning:\n```\nFatal: unable to save snapshot: no space left on device\n```\nPruning snapshots older than 90 days would free about **212 GB**. Want me to do it?", 588),
                me(1004, 0, "Yes, go ahead", 585),
                approvalMessage(id: 1005, now: t(584)),
                me(1006, 0, "Here's the video from Saturday for Léa", 120),
                ChatMessage(id: 1007, topic: 0, date: t(119), isOutgoing: true,
                            text: FormattedText("Too big for Telegram, so it went through Gofile.\n[fichier: https://gofile.io/d/Qp9w8eR7]")),
                bot(1008, 0, "Got it, I sent Léa the link with a note that it expires in 10 days.", 118),
                me(1009, 0, "Remind me to call mum tonight", 30),
                bot(1010, 0, "Done: a reminder at 19:30 today, in Reminders on your iPhone.", 29),
            ],
            12: [
                me(2001, 12, "Can you check why the Hermes gateway restarted twice yesterday?", 1500),
                bot(2002, 12, "Both restarts were launchd bringing it back after a crash in the Telegram adapter, at 14:02 and 17:45. The second log line says `RetryAfter: 29`; it hit a flood limit while editing a long draft. I've opened a fix on a branch: `fix/telegram-flood-wait`.", 1495),
            ],
            31: [
                bot(3001, 31, "This sub-chat is encrypted. Your 2025 statements are in the vault; I've filled in the first two sections of the form.", 3000),
            ],
            44: [
                me(4001, 44, "Find a quiet place to stay near Alfama, 3 nights from the 14th", 4000),
                bot(4002, 44, "Three options under €160 a night, all with good reviews for quiet:\n1. **Casa do Largo**: €142, terrace, 4 min from the tram\n2. **Alfama Patio**: €155, breakfast included\n3. **Memmo Alfama**: €159, pool, the most central\nShall I hold one?", 3990),
            ],
            57: [
                bot(5001, 57, "Saved: “The Pragmatic Programmer”, 20th anniversary edition.", 9000),
            ],
        ]
    }

    public static func approvalMessage(id: MessageID, now: Date) -> ChatMessage {
        let options = [("Once", "ea:once:7"), ("Session", "ea:session:7"), ("Always", "ea:always:7"), ("Deny", "ea:deny:7")]
        return ChatMessage(
            id: id, topic: 0, date: now, isOutgoing: false,
            text: FormattedText("⚠️ Dangerous command: restic forget --keep-within 90d --prune"),
            buttons: options.enumerated().map { i, o in
                InlineButton(row: i < 3 ? 0 : 1, column: i < 3 ? i : 0, label: o.0, action: .callback(Data(o.1.utf8)))
            })
    }

    public static func approvalQuestion(messageID: MessageID) -> PendingQuestion {
        PendingQuestion(
            id: "ea:7", kind: .approval, chat: .main, messageID: messageID,
            text: "Dangerous command: restic forget --keep-within 90d --prune",
            spoken: "Hermes asks to delete backups older than ninety days. Allow?",
            summary: "Delete backup snapshots older than 90 days to free about 212 GB on the external disk",
            command: "restic -r /Volumes/Backup/restic forget --keep-within 90d --prune",
            options: [
                QuestionOption(id: "once", label: "Once", data: Data("ea:once:7".utf8)),
                QuestionOption(id: "session", label: "Session", data: Data("ea:session:7".utf8)),
                QuestionOption(id: "always", label: "Always", data: Data("ea:always:7".utf8)),
                QuestionOption(id: "deny", label: "Deny", data: Data("ea:deny:7".utf8)),
            ], askedAt: .now)
    }

    public static func state(now: Date) -> AppState {
        AppState(
            agent: AgentState(status: .waitingUser, task: "Waiting for your approval", since: now.addingTimeInterval(-90), chat: .main),
            questions: [approvalQuestion(messageID: 1005)],
            pet: PetState(id: "pip", name: "Pip", version: 3,
                          spriteMessageID: 790,
                          manifest: PetManifest(id: "pip", displayName: "Pip", description: "A small winged messenger."), mood: "content", hunger: 0.35, energy: 0.7, happiness: 0.82,
                          xp: 2240, level: 6, xpForNextLevel: 2800),
            subchats: [
                SubchatInfo(topicID: 31, name: "Taxes 2026", preset: "secret", encrypted: true, unlocked: false),
                SubchatInfo(topicID: 12, name: "Home server", preset: "project"),
                SubchatInfo(topicID: 44, name: "Lisbon trip", preset: "aside", ttl: "session"),
                SubchatInfo(topicID: 57, name: "Reading list", preset: "project"),
            ],
            slots: ["stats": 802, "devices": 801, "sprite": 790])
    }

    public static func appMessage(id: MessageID, json: String) -> ChatMessage {
        ChatMessage(id: id, topic: FakeTelegramClient.appTopic, date: .now, isOutgoing: false,
                    text: FormattedText(json, entities: [TextEntity(offset: 0, length: json.utf16.count, kind: .pre(language: "json"))]))
    }

    /// Serializes a state the way the backend does, so the fake goes through the real decoder.
    public static func stateJSON(_ s: AppState) -> String {
        var o: [String: Any] = ["v": 1, "type": "state"]
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
                        "hunger": Int(p.hunger * 100), "energy": Int(p.energy * 100), "happiness": Int(p.happiness * 100),
                        "xp": p.xp, "level": p.level, "xp_next": p.xpForNextLevel ?? 0, "asleep": p.asleep]
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

    static func answer(to text: String) -> String {
        let l = text.lowercased()
        if l.hasPrefix("/sub new") {
            return "Opened a new sub-chat. You'll find it in the sidebar."
        }
        if l.contains("weather") || l.contains("météo") {
            return "Lisbon on Thursday: **21°C** and sunny, a light breeze off the river in the evening. Pack a thin jacket."
        }
        return "On it. I checked the server: CPU is at **12%**, memory at 50%, and the backup disk now has 212 GB free after last night's prune. Nothing else needs you right now; I'll ping you if the nightly run fails again."
    }
}
