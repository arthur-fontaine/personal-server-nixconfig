import Foundation

/// A big file sent outside Telegram, written `[fichier: <url>]` at the end of a message
/// (app-protocol.md, "Big files"). Both the app and Hermes write and read it.
public struct FileLink: Hashable, Sendable, Codable {
    public var url: URL

    public init(url: URL) { self.url = url }

    /// The file's name as far as the URL tells: the last path component when it looks like a
    /// file name, else the host ("gofile.io").
    public var displayName: String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if last.contains(".") && last != "/" { return last }
        return url.host() ?? url.absoluteString
    }

    public var service: String {
        guard let host = url.host()?.lowercased() else { return "link" }
        if host.hasSuffix("swisstransfer.com") { return "SwissTransfer" }
        if host.hasSuffix("gofile.io") { return "Gofile" }
        return host
    }

    // `[fichier: url]`, tolerant of case, of extra spaces and of `<url>` brackets.
    // The URL runs to the closing bracket; no URL we produce contains one.
    nonisolated(unsafe) private static let pattern = #/\[\s*(?i:fichier)\s*:\s*<?(?<url>[^\]\s>]+)>?\s*\]/#

    public static func parse(_ text: String) -> [FileLink] {
        text.matches(of: pattern).compactMap { match in
            guard let url = URL(string: String(match.output.url)),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
            return FileLink(url: url)
        }
    }

    /// Removes the markers and the blank lines they leave.
    public static func strip(from text: String) -> String {
        guard text.contains("[") else { return text }
        var out = text.replacing(pattern, with: "")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appends one marker per line at the end of `text`.
    public static func append(_ links: [FileLink], to text: String) -> String {
        guard !links.isEmpty else { return text }
        let markers = links.map { "[fichier: \($0.url.absoluteString)]" }.joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? markers : trimmed + "\n" + markers
    }
}
