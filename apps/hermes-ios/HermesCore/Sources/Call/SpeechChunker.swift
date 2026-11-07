import Foundation

/// Turns Hermes' streamed answer into sentences to speak, as soon as each one is complete.
/// Feed it the whole text so far at each draft/edit; it returns only the new sentences.
/// Text that changed behind what was spoken (a rewrite) is not spoken twice.
public struct SpeechChunker: Sendable {
    /// Characters of the source text already turned into sentences.
    public private(set) var consumed = 0
    private var lastText = ""

    public init() {}

    /// New complete sentences in `text`; `final` flushes the remainder.
    public mutating func feed(_ text: String, final: Bool = false) -> [String] {
        // A rewrite of what was already spoken: only what comes after the common prefix counts.
        if !text.hasPrefix(lastText.prefix(consumed)) {
            consumed = min(consumed, text.commonPrefix(with: lastText).count)
        }
        lastText = text
        let chars = Array(text)
        var out: [String] = []
        var start = consumed
        var i = consumed
        var inFence = false
        while i < chars.count {
            if i + 2 < chars.count, chars[i] == "`", chars[i + 1] == "`", chars[i + 2] == "`" {
                inFence.toggle()
                i += 3
                continue
            }
            let c = chars[i]
            let atEnd = i + 1 >= chars.count
            let boundary: Bool
            if inFence {
                boundary = false
            } else if c == "\n" {
                boundary = true
            } else if ".!?…;".contains(c) {
                // "3.5", "e.g." or an ellipsis in progress aren't ends; a space or newline after is.
                boundary = !atEnd && (chars[i + 1] == " " || chars[i + 1] == "\n")
            } else {
                boundary = false
            }
            if boundary {
                appendSpoken(String(chars[start...i]), to: &out)
                start = i + 1
            }
            i += 1
        }
        if final {
            if inFence { appendSpoken("A code block.", to: &out) }
            else if start < chars.count { appendSpoken(String(chars[start...]), to: &out) }
            start = chars.count
        } else if inFence {
            // Don't consume an open code block: it is spoken as one phrase once closed.
            start = min(start, fenceStart(chars, from: consumed) ?? start)
        }
        consumed = max(consumed, start)
        return out
    }

    private func fenceStart(_ chars: [Character], from: Int) -> Int? {
        var i = from
        var open: Int?
        while i + 2 < chars.count {
            if chars[i] == "`", chars[i + 1] == "`", chars[i + 2] == "`" {
                open = open == nil ? i : nil
                i += 3
            } else { i += 1 }
        }
        return open
    }

    private func appendSpoken(_ raw: String, to out: inout [String]) {
        let s = Self.speakable(raw)
        if s.contains(where: \.isLetter) || s.contains(where: \.isNumber) { out.append(s) }
    }

    /// Markdown, links and code made speakable: what a person would read out.
    public static func speakable(_ text: String) -> String {
        var s = text
        // Code blocks become a mention; inline code keeps its words.
        s = s.replacing(#/```[\s\S]*?```/#, with: " a code block ")
        s = s.replacing(#/\[fichier:[^\]]*\]/#, with: " a file ")
        s = s.replacing(#/\[([^\]]+)\]\((https?:[^)]+)\)/#) { String($0.output.1) }
        s = s.replacing(#/https?://([^/\s]+)\S*/#) { "a link to " + String($0.output.1) }
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacing(#/[*_~#>]+/#, with: "")
        s = s.replacing(#/^\s*[-•]\s+/#.anchorsMatchLineEndings(), with: "")
        s = s.replacing(#/^\s*\d+[.)]\s+/#.anchorsMatchLineEndings(), with: "")
        s = s.replacingOccurrences(of: "🎙", with: "")
        s = s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000 && !$0.properties.isASCIIHexDigit)) }
            .map(String.init).joined()
        s = s.replacing(#/\s+/#, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
