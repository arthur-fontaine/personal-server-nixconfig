import Foundation

/// What of Hermes' Telegram text is for the app rather than for reading (protocol §6, v4):
/// a `🔊 …` line (an older spoken-variant mechanism: never shown), the `📎 ` marker of a call's
/// details message (shown, never spoken), and the "⏩ Steered into current run…" notice (the
/// owner's bubble shows that state instead). The server strips these too; the app is robust to
/// both.
public enum MessageCleanup {
    public static let spokenMarker = "🔊"
    public static let detailsMarker = "📎"
    public static let steerMarker = "⏩"

    /// Hermes' text as the app shows it, and whether it is a call's details message.
    public static func shown(_ t: FormattedText) -> (text: FormattedText, isCallDetails: Bool) {
        var removed: [Range<Int>] = []
        let utf16 = Array(t.text.utf16)
        var isDetails = false
        // Lines, as UTF-16 ranges, newline included.
        var start = 0
        var lines: [Range<Int>] = []
        for (i, u) in utf16.enumerated() where u == 0x0A {
            lines.append(start..<(i + 1))
            start = i + 1
        }
        if start < utf16.count { lines.append(start..<utf16.count) }
        for line in lines {
            let content = String(decoding: utf16[line], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasPrefix(spokenMarker) { removed.append(line) }
        }
        let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(detailsMarker), let first = lines.first {
            isDetails = true
            // The marker and the spaces after it.
            let lead = t.text.utf16.count - t.text.drop { $0.isWhitespace }.utf16.count
            var end = lead + detailsMarker.utf16.count
            while end < first.upperBound, end < utf16.count, utf16[end] == 0x20 || utf16[end] == 0xFE0F { end += 1 }
            removed.append(0..<end)
        }
        guard !removed.isEmpty else { return (t, false) }
        return (trimmed(removing(removed, from: t)), isDetails)
    }

    /// The server's notice that a message was steered into the running turn.
    public static func isSteerNotice(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(steerMarker)
    }

    /// What a call speaks of a streaming answer: everything before a details part or a `🔊` line.
    public static func speakable(_ text: String) -> String {
        var out: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix(detailsMarker) { break }
            if l.hasPrefix(spokenMarker) { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// `t` without the UTF-16 ranges, its entities moved (or cut) to match.
    static func removing(_ ranges: [Range<Int>], from t: FormattedText) -> FormattedText {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        let utf16 = Array(t.text.utf16)
        var kept: [UInt16] = []
        var cursor = 0
        for r in sorted where r.lowerBound >= cursor {
            kept += utf16[cursor..<r.lowerBound]
            cursor = r.upperBound
        }
        kept += utf16[min(cursor, utf16.count)...]
        func map(_ offset: Int) -> Int {
            var shift = 0
            for r in sorted {
                if offset >= r.upperBound { shift += r.count } else if offset > r.lowerBound { shift += offset - r.lowerBound }
            }
            return offset - shift
        }
        let entities = t.entities.compactMap { e -> TextEntity? in
            let s = map(e.offset), end = map(e.offset + e.length)
            return end > s ? TextEntity(offset: s, length: end - s, kind: e.kind) : nil
        }
        return FormattedText(String(decoding: kept, as: UTF16.self), entities: entities)
    }

    /// Trailing whitespace off, entities clipped to what remains.
    static func trimmed(_ t: FormattedText) -> FormattedText {
        let text = String(t.text.reversed().drop { $0.isWhitespace }.reversed())
        let n = text.utf16.count
        let entities = t.entities.compactMap { e -> TextEntity? in
            let end = min(e.offset + e.length, n)
            return end > e.offset ? TextEntity(offset: e.offset, length: end - e.offset, kind: e.kind) : nil
        }
        return FormattedText(text, entities: entities)
    }
}

/// A question as the card shows it (brief item 4): Hermes' clarify text lists the choices
/// ("1. … 2. …") and a "Reply "skip"…" hint for Telegram; the card's buttons are the choices, so
/// both go, and a button still labelled with a bare number takes its choice's text.
public enum QuestionText {
    public static func display(_ q: PendingQuestion) -> PendingQuestion {
        var q = q
        let lines = q.text.components(separatedBy: "\n")
        var choices: [String: String] = [:]
        for line in lines {
            if let (n, choice) = numbered(line) { choices[n] = choice }
        }
        q.options = q.options.map { o in
            var o = o
            if let choice = choices[o.label.trimmingCharacters(in: .whitespaces)] { o.label = choice }
            return o
        }
        let labels = Set(q.options.map(\.label))
        // A numbered line goes only when the buttons say the same thing: a list in the question
        // itself ("Steps: 1. …") stays.
        let drop: (String) -> Bool = { line in
            if isSkipHint(line) { return true }
            guard let (_, choice) = numbered(line) else { return false }
            return labels.contains(choice)
        }
        var kept = lines.filter { !drop($0) }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        var text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Telegram's clarify cards open with "❓ ": the card is already a question.
        if text.hasPrefix("❓") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        q.text = text
        return q
    }

    static func numbered(_ line: String) -> (String, String)? {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard let dot = l.firstIndex(of: "."), !l[..<dot].isEmpty, l[..<dot].allSatisfy(\.isNumber) else { return nil }
        let rest = l[l.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : (String(l[..<dot]), rest)
    }

    /// Hermes' `gateway.clarify.skip_hint` in any of its languages: the word skip, quoted.
    static func isSkipHint(_ line: String) -> Bool {
        let quoted = ["\"skip\"", "“skip”", "« skip »", "«skip»", "„skip“", "„skip”", "'skip'", "「skip」"]
        return quoted.contains { line.contains($0) }
    }
}
