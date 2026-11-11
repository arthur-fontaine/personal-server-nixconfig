import Foundation

/// The demo's memory (protocol §4.1): the main chat's volume, two sub-chats', and the private
/// Taxes one, locked until the app unlocks the sub-chat. The view and the first halves are
/// written out; deeper lines and messages are made up from a few sentences, deterministically.
public enum MemoryFixtures {
    struct Volume {
        var chat: TopicID
        var name: String?
        var volume: String
        var count: Int
        var isPrivate = false
        var view: [(Int, Int)]
        var texts: [String: String]
        var phrases: [String]
    }

    static let main = Volume(
        chat: .main, name: "Main chat", volume: "main", count: 3670,
        view: [(0, 2048), (2048, 1024), (3072, 512), (3584, 64), (3648, 16), (3664, 4), (3668, 1), (3669, 1)],
        texts: [
            "0+2048": L("Set up the server and Hermes in October: nix-darwin, the Telegram bot, the memory, nightly restic backups to the external disk. Arthur likes short answers, and French after 9 pm."),
            "2048+1024": L("Moved Home Assistant to the Mac, fixed the Wi-Fi plug in the living room, wrote the morning summary. Started planning Lisbon with Léa, Thursday to Sunday."),
            "3072+512": L("Taxes moved to a private sub-chat. The reading list began. The nightly backup warned twice about free space on the external disk."),
            "3584+64": L("Booked the Alfama flat (€420 for three nights). Léa confirmed Saturday dinner. Arthur asked for a reminder to renew his passport before March."),
            "3648+16": L("The backup failed at 03:12: the external disk was full. Hermes proposed pruning snapshots older than 90 days, about 212 GB."),
            "3664+4": L("Arthur asked what happened with the backup; Hermes showed restic's error and asked before pruning."),
            "3668+1": L("Arthur: go ahead and prune, but keep the March snapshots."),
            "0+1024": L("First week: installed nix-darwin and Hermes, paired the Telegram bot, chose the models, and tested the memory on a few old notes."),
            "1024+1024": L("Second week: backups with restic, the guard's approval rules, the morning summary, and the first sub-chats."),
            "2048+512": L("Home Assistant moved to the Mac; Hermes learned the house's devices and the evening routine."),
            "2560+512": L("Lisbon: flights compared, Thursday 10:40 from Orly chosen; Léa joins on Friday."),
            "3072+256": L("Taxes paperwork listed and moved to a private sub-chat; Hermes keeps nothing of it here."),
            "3328+256": L("Reading list started with 12 essays; two backup warnings about the disk filling up."),
            "3584+32": L("Looked at flats in Alfama and Graça; the Alfama one has a terrace and a quiet street."),
            "3616+32": L("Booked it, shared the address with Léa, added the passport reminder for February."),
            "3648+8": L("03:12, restic: no space left on device. Hermes checked the disk: 1.9 of 2 TB used."),
            "3656+8": L("Hermes worked out that pruning past 90 days frees 212 GB, and waited for Arthur."),
            "3664+2": L("Arthur asked about the backup; Hermes quoted restic's error."),
            "3666+2": L("Hermes offered to prune the old snapshots and asked for a go-ahead."),
        ],
        phrases: [
            L("Checked the backup logs and the disk's free space."),
            L("Talked through the week's plan and moved two reminders."),
            L("Answered a question about the heating schedule."),
            L("Summarized the morning: weather, calendar, two emails worth reading."),
            L("Fixed a failing Home Assistant automation after a firmware update."),
            L("Compared train and flight times for a weekend away."),
            L("Read an article Arthur sent and kept its three main points."),
            L("Updated the server and rebuilt it; nothing broke."),
        ])

    static let homeServer = Volume(
        chat: 12, name: "Home server", volume: "chat-5d1a0c2e9b7f4a13", count: 300,
        view: [(0, 256), (256, 32), (288, 8), (296, 4)],
        texts: [
            "0+256": L("The Mac mini's setup: Home Assistant, the media share, the router's DHCP reservations."),
            "256+32": L("Moved the media share to the new disk and checked its permissions."),
            "288+8": L("The living room plug kept dropping off Wi-Fi: moved it to the 2.4 GHz network."),
            "296+4": L("Arthur asked for the server's uptime; Hermes reported 41 days."),
        ],
        phrases: [L("Looked at the router's logs."), L("Restarted Home Assistant after an update."),
                  L("Checked the media share's free space."), L("Renamed two devices in Home Assistant.")])

    static let lisbon = Volume(
        chat: 44, name: "Lisbon trip", volume: "chat-9e04b7c1d2a83f56", count: 24,
        view: [(0, 16), (16, 8)],
        texts: [
            "0+16": L("Hotels compared near Alfama; Arthur chose the one with the terrace."),
            "16+8": L("Weather for the weekend: sunny, 22 °C on Saturday."),
        ],
        phrases: [L("Looked up the tram to the castle."), L("Found a restaurant for Saturday."),
                  L("Checked the flight's gate."), L("Listed what to pack.")])

    static let taxes = Volume(
        chat: 31, name: "Taxes 2026", volume: "chat-41f3a9be07c25d18", count: 40, isPrivate: true,
        view: [(0, 32), (32, 8)],
        texts: [
            "0+32": L("Listed the documents for the 2026 return: payslips, the rent receipts, two donation receipts."),
            "32+8": L("The deduction for the home office applies; Hermes filled in the form's draft."),
        ],
        phrases: [L("Read a payslip."), L("Added a donation receipt."), L("Checked a deduction's rules."), L("Drafted a line of the form.")])

    static let all = [main, homeServer, lisbon, taxes]

    // MARK: Replies (`data` of memory.volumes and memory.lines)

    public static func volumesData(taxesUnlocked: Bool) -> [String: Any] {
        ["volumes": all.map { v in
            let locked = v.isPrivate && !taxesUnlocked
            return ["chat": Int(v.chat), "name": v.name ?? NSNull(), "volume": v.volume,
                    "messages": locked ? NSNull() : v.count as Any, "locked": locked, "private": v.isPrivate] as [String: Any]
        }]
    }

    /// The `data` of a memory.lines request, or the error code it fails with.
    public static func linesData(_ request: [String: Any], taxesUnlocked: Bool, now: Date = .now) -> Result<[String: Any], ErrorCode> {
        let chat = (request["chat"] as? NSNumber)?.int32Value ?? 0
        guard let v = all.first(where: { $0.chat == chat }) else { return .failure(.notFound) }
        if v.isPrivate && !taxesUnlocked { return .failure(.locked) }
        guard let first = (request["first"] as? NSNumber)?.intValue, let n = (request["n"] as? NSNumber)?.intValue else {
            let after = (request["after"] as? NSNumber)?.intValue ?? 0
            let lines = v.view.filter { $0.0 >= after }.map { line(v, $0.0, $0.1) }
            // Two pages for the main view, as a long one would come.
            if v.chat == .main, after == 0 {
                return .success(["lines": Array(lines.prefix(5)), "truncated": true, "next": v.view[5].0])
            }
            return .success(["lines": lines])
        }
        guard n >= 1, n & (n - 1) == 0, first >= 0, first % n == 0 else { return .failure(.badRequest) }
        guard first + n <= v.count else { return .failure(.notFound) }
        if n == 1 { return .success(["message": message(v, first, now: now)]) }
        return .success(["lines": [line(v, first, n / 2), line(v, first + n / 2, n / 2)]])
    }

    public enum ErrorCode: String, Error { case notFound = "not_found", locked, badRequest = "bad_request" }

    static func line(_ v: Volume, _ first: Int, _ n: Int) -> [String: Any] {
        // The newest message isn't summarized yet.
        if first == v.count - 1 && n == 1 { return ["first": first, "n": n, "text": NSNull(), "built": false] }
        let text = v.texts["\(first)+\(n)"] ?? phrase(v, first, n)
        return ["first": first, "n": n, "text": text, "built": true]
    }

    static func phrase(_ v: Volume, _ first: Int, _ n: Int) -> String {
        let a = v.phrases[(first / n) % v.phrases.count]
        guard n > 1 else { return a }
        let b = v.phrases[(first / n + n.trailingZeroBitCount + 1) % v.phrases.count]
        return a == b ? a : "\(a) \(b)"
    }

    static func message(_ v: Volume, _ i: Int, now: Date) -> [String: Any] {
        let date = now.addingTimeInterval(-Double(v.count - i) * 1200)
        let iso = ISO8601DateFormatter().string(from: date)
        if v.chat == .main, i == 3668 {
            return ["i": i, "kind": "user", "date": iso, "text": L("Go ahead and prune, but keep the March snapshots.")]
        }
        if v.chat == .main, i == 3669 {
            return ["i": i, "kind": "hermes", "date": iso,
                    "text": L("On it: pruning everything older than 90 days except March's 4 snapshots. I'll tell you when it's done.")]
        }
        let kind = i % 2 == 0 ? "user" : (i % 6 == 3 ? "tool" : "hermes")
        let text = switch kind {
        case "user": L("Can you look at this? \(phrase(v, i, 1))")
        case "tool": "terminal: df -h /Volumes/Backup\n/dev/disk4s1  1.8Ti  1.7Ti  112Gi  94%  /Volumes/Backup"
        default: L("Done. \(phrase(v, i, 1)) Nothing else needs your attention.")
        }
        return ["i": i, "kind": kind, "date": iso, "text": text]
    }
}
