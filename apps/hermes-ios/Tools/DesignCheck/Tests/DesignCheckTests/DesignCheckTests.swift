import DesignCheckCore
import Foundation
import Testing

/// Each fixture names its kind (`<kind>__name.swift`) and the rules it must trip on its first
/// line (`// expect: rule rule…`, empty for a clean file): the checker must report exactly those.
struct DesignCheckTests {
    static let fixtures: [URL] = {
        let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        return try! FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    @Test(arguments: fixtures)
    func fixture(_ url: URL) throws {
        let source = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
        let kind = try #require(FileKind(rawValue: String(name.split(separator: "_").first!)))
        let header = try #require(source.split(separator: "\n").first)
        let expected = Set(header.replacingOccurrences(of: "// expect:", with: "").split(separator: " ").map(String.init))
        let found = Set(DesignCheck.check(source: source, file: name, kind: kind).map(\.rule.rawValue))
        #expect(found == expected, "\(name): found \(found.sorted()), expected \(expected.sorted())")
    }

    @Test func everyRuleHasAFixture() {
        let covered = Set(Self.fixtures.flatMap { url -> [String] in
            let first = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").first ?? ""
            return first.replacingOccurrences(of: "// expect:", with: "").split(separator: " ").map(String.init)
        })
        for rule in Rule.allCases { #expect(covered.contains(rule.rawValue), "no fixture trips \(rule.rawValue)") }
    }
}
