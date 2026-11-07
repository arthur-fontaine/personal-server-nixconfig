import Foundation

/// A message cut into what renders differently: prose paragraphs and code blocks. Paragraphs are
/// separate so a streaming message only re-lays out its last one.
public enum MessageSegment: Hashable, Sendable {
    case text(AttributedString)
    case code(String, language: String?)
    case quote(AttributedString)
}

public enum MessageSegments {
    public static func make(_ formatted: FormattedText, hidingFileLinks: Bool = true) -> [MessageSegment] {
        var text = formatted.text
        var entities = formatted.entities
        if hidingFileLinks, !FileLink.parse(text).isEmpty {
            // Markers sit at the end (protocol §7): cutting the tail keeps every entity offset valid.
            let stripped = FileLink.strip(from: text)
            if text.hasPrefix(stripped) {
                let cut = stripped.utf16.count
                entities = entities.filter { $0.offset + $0.length <= cut }
                text = stripped
            } else {
                text = stripped
                entities = []
            }
        }
        let utf16 = Array(text.utf16)

        // Block-level entities split the text; everything else is inline styling.
        let blocks = entities.filter {
            if case .pre = $0.kind { return true }
            if case .blockquote = $0.kind { return true }
            return false
        }.sorted { $0.offset < $1.offset }

        var segments: [MessageSegment] = []
        var cursor = 0
        func slice(_ from: Int, _ to: Int) -> String {
            let a = max(0, min(from, utf16.count)), b = max(a, min(to, utf16.count))
            return String(decoding: utf16[a..<b], as: UTF16.self)
        }
        func inline(_ from: Int, _ to: Int) {
            guard to > from else { return }
            let chunk = slice(from, to)
            let local = entities.compactMap { e -> TextEntity? in
                let s = max(e.offset, from), end = min(e.offset + e.length, to)
                guard end > s, !isBlock(e.kind) else { return nil }
                return TextEntity(offset: s - from, length: end - s, kind: e.kind)
            }
            for para in paragraphs(chunk, entities: local) { segments.append(.text(para)) }
        }
        for b in blocks where b.offset >= cursor {
            inline(cursor, b.offset)
            let body = slice(b.offset, b.offset + b.length)
            switch b.kind {
            case .pre(let lang):
                segments.append(.code(body.trimmingCharacters(in: .newlines), language: lang?.isEmpty == false ? lang : nil))
            default:
                let local = entities.compactMap { e -> TextEntity? in
                    let s = max(e.offset, b.offset), end = min(e.offset + e.length, b.offset + b.length)
                    guard end > s, !isBlock(e.kind) else { return nil }
                    return TextEntity(offset: s - b.offset, length: end - s, kind: e.kind)
                }
                segments.append(.quote(attributed(body.trimmingCharacters(in: .newlines), entities: local)))
            }
            cursor = b.offset + b.length
        }
        inline(cursor, utf16.count)
        return segments
    }

    static func isBlock(_ k: TextEntity.Kind) -> Bool {
        if case .pre = k { return true }
        if case .blockquote = k { return true }
        return false
    }

    /// Splits on blank lines, keeping entity offsets right in each paragraph.
    static func paragraphs(_ text: String, entities: [TextEntity]) -> [AttributedString] {
        let utf16 = Array(text.utf16)
        var out: [AttributedString] = []
        var start = 0
        var i = 0
        let newline = UInt16(UInt8(ascii: "\n"))
        func flush(_ end: Int) {
            var s = start, e = end
            while s < e, utf16[s] == newline { s += 1 }
            while e > s, utf16[e - 1] == newline { e -= 1 }
            guard e > s else { return }
            let piece = String(decoding: utf16[s..<e], as: UTF16.self)
            let local = entities.compactMap { en -> TextEntity? in
                let a = max(en.offset, s), b = min(en.offset + en.length, e)
                return b > a ? TextEntity(offset: a - s, length: b - a, kind: en.kind) : nil
            }
            out.append(attributed(piece, entities: local))
        }
        while i < utf16.count - 1 {
            if utf16[i] == newline, utf16[i + 1] == newline {
                flush(i)
                while i < utf16.count, utf16[i] == newline { i += 1 }
                start = i
            } else { i += 1 }
        }
        flush(utf16.count)
        return out
    }

    public static func attributed(_ text: String, entities: [TextEntity]) -> AttributedString {
        var a = AttributedString(text)
        for e in entities {
            guard let lower = index(text, utf16: e.offset), let upper = index(text, utf16: e.offset + e.length),
                  lower < upper, let range = Range(lower..<upper, in: a) else { continue }
            switch e.kind {
            case .bold: a[range].inlinePresentationIntent = (a[range].inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            case .italic: a[range].inlinePresentationIntent = (a[range].inlinePresentationIntent ?? []).union(.emphasized)
            case .strikethrough: a[range].inlinePresentationIntent = (a[range].inlinePresentationIntent ?? []).union(.strikethrough)
            case .code: a[range].inlinePresentationIntent = (a[range].inlinePresentationIntent ?? []).union(.code)
            case .underline: a[range].inlinePresentationIntent = (a[range].inlinePresentationIntent ?? []).union(.emphasized)
            case .url:
                let s = String(text[lower..<upper])
                a[range].link = URL(string: s.contains("://") ? s : "https://" + s)
            case .textURL(let u): a[range].link = URL(string: u)
            case .spoiler, .mention, .botCommand, .pre, .blockquote: break
            }
        }
        return a
    }

    static func index(_ s: String, utf16 offset: Int) -> String.Index? {
        guard offset >= 0, offset <= s.utf16.count else { return nil }
        return String.Index(utf16Offset: offset, in: s)
    }
}

/// Reveals streamed text at a steady pace: drafts arrive in bursts every few hundred ms; showing
/// each burst at once reads as jumps. Each tick reveals a share of what is left, so it catches up
/// within ~8 frames whatever the burst size, and never lags more than a moment.
public struct StreamSmoother: Sendable {
    public private(set) var target: String = ""
    public private(set) var shownCount: Int = 0

    public init() {}

    public var shown: String { String(target.prefix(shownCount)) }
    public var isCaughtUp: Bool { shownCount >= target.count }

    public mutating func update(_ text: String) {
        // An edit that rewrote earlier text (not an append) restarts from the common prefix.
        if !text.hasPrefix(String(target.prefix(shownCount))) {
            shownCount = target.commonPrefix(with: text).count
        }
        target = text
        shownCount = min(shownCount, text.count)
    }

    /// One display frame. Returns whether anything changed.
    @discardableResult
    public mutating func tick() -> Bool {
        let remaining = target.count - shownCount
        guard remaining > 0 else { return false }
        shownCount += max(1, Int((Double(remaining) / 8).rounded(.up)))
        shownCount = min(shownCount, target.count)
        return true
    }

    public mutating func finish() { shownCount = target.count }
}
