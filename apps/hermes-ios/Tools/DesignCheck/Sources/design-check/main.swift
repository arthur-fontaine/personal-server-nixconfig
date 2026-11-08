import DesignCheckCore
import Foundation

// design-check --screens <dir|file>… --ui <HermesUI/Sources> [--legacy <list>]
// Prints Xcode-style errors and exits 1 on any finding, so the build phase fails.
var screens: [String] = [], ui: [String] = [], legacyFile: String?
var mode = ""
for arg in CommandLine.arguments.dropFirst() {
    switch arg {
    case "--screens", "--ui", "--legacy": mode = arg
    default:
        switch mode {
        case "--screens": screens.append(arg)
        case "--ui": ui.append(arg)
        case "--legacy": legacyFile = arg
        default: FileHandle.standardError.write(Data("usage: design-check --screens … --ui … [--legacy list]\n".utf8)); exit(2)
        }
    }
}

func swiftFiles(_ path: String) -> [String] {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue { return path.hasSuffix(".swift") ? [path] : [] }
    let e = FileManager.default.enumerator(atPath: path)
    return (e?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") }.map { "\(path)/\($0)" }.sorted()
}

/// Screens not yet moved to HermesUI (phase 2 of the redesign): listed, one path per line, so
/// the list only shrinks. A listed file that no longer exists is an error too.
var legacy: Set<String> = []
if let legacyFile, let text = try? String(contentsOfFile: legacyFile, encoding: .utf8) {
    let base = (legacyFile as NSString).deletingLastPathComponent
    for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
        let path = (base as NSString).appendingPathComponent(String(line).trimmingCharacters(in: .whitespaces))
        legacy.insert((path as NSString).standardizingPath)
    }
}

var findings: [Finding] = []
var checked = 0
for path in screens.flatMap(swiftFiles) where !legacy.contains((path as NSString).standardizingPath) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    findings += DesignCheck.check(source: source, file: path, kind: .screen)
    checked += 1
}
for path in ui.flatMap(swiftFiles) {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
    let kind: FileKind = path.contains("/Chrome/") ? .chrome : (path.hasSuffix("/Tokens/Tokens.swift") ? .tokens : .ui)
    findings += DesignCheck.check(source: source, file: path, kind: kind)
    checked += 1
}
for missing in legacy where !FileManager.default.fileExists(atPath: missing) {
    print("\(legacyFile ?? ""):1:1: error: [design legacy] \(missing) is listed as not yet migrated but doesn't exist: remove it from the list")
    findings.append(Finding.placeholder)
}
for f in findings where f != .placeholder { print(f) }
print("design-check: \(checked) files, \(findings.count) finding(s)\(legacy.isEmpty ? "" : ", \(legacy.count) screen(s) waiting for phase 2")")
exit(findings.isEmpty ? 0 : 1)
