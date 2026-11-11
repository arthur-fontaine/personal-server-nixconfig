import Foundation

/// A resolved element, ready to draw: its props read into a typed `kind`, its children expanded
/// (`repeat`) and filtered (`visible`), its expressions evaluated against the state.
public struct UINode: Sendable, Equatable, Identifiable {
    /// Unique in the tree: the element's key, plus the repeat items it sits in.
    public var id: String
    public var key: String
    public var kind: UIKind
    public var children: [UINode]
    /// Where a choice (`Tabs`, `ButtonGroup`, `Select`) keeps its value: the `$bindState` path, or
    /// a local one.
    public var valuePath: String?
    var bindings: [String: [UIActionBinding]]
    var scope: UIScope
}

public enum UIKind: Sendable, Equatable {
    case card(title: String?, description: String?)
    case stack(axis: DynamicUIAxis, gap: UIGap, align: UIAlign, justify: UIJustify)
    case grid(columns: Int, gap: UIGap)
    case separator
    case heading(String)
    case text(String, variant: UITextVariant)
    case badge(String, variant: UIBadgeVariant)
    /// `symbol`: the SF Symbol for the Lucide `name`.
    case icon(name: String, symbol: String, size: UISize, color: UIColorRole)
    case image(url: URL?, alt: String)
    case metric(UIMetric)
    case progress(fraction: Double, label: String?)
    case alert(title: String, message: String?, type: UIAlertType)
    case table(columns: [String], rows: [[String]], caption: String?)
    case barGraph(title: String?, data: [UIDataPoint])
    case lineGraph(title: String?, data: [UIDataPoint])
    case button(label: String, variant: UIButtonVariant, disabled: Bool)
    case buttonGroup(options: [UIOption], selected: String?)
    case select(label: String, options: [UIOption], value: String?)
    case tabs(options: [UIOption], selected: String?)
    /// A type the app doesn't draw: nothing.
    case unknown(String)
}

public enum DynamicUIAxis: Sendable { case vertical, horizontal }
public enum UIGap: Sendable { case none, small, medium, large, extraLarge }
public enum UIAlign: Sendable { case start, center, end, stretch }
public enum UIJustify: Sendable { case start, center, end, between, around }
public enum UITextVariant: Sendable { case body, caption, muted, lead, code }
public enum UIBadgeVariant: Sendable { case `default`, secondary, destructive, outline }
public enum UISize: Sendable { case small, medium, large }
public enum UIColorRole: Sendable { case `default`, muted, primary, success, warning, danger }
public enum UIAlertType: Sendable { case info, success, warning, error }
public enum UIButtonVariant: Sendable { case primary, secondary, danger }
public enum UIChange: Sendable { case positive, negative, neutral }

public struct UIMetric: Sendable, Equatable {
    public var label: String
    /// The value with its prefix and suffix.
    public var value: String
    public var change: String?
    public var changeType: UIChange
}

public struct UIDataPoint: Sendable, Equatable, Identifiable {
    public var id: Int
    public var label: String
    public var value: Double
}

public struct UIOption: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { value }
    public var label: String
    public var value: String
}

/// Where an element sits in repeats: the item, its index, its absolute state path.
struct UIScope: Sendable, Equatable {
    var item: JSONValue?
    var index: Int?
    var basePath: String?
}

public enum DynamicUI {
    /// Limits on what a spec expands to (a repeat over a long list, a deep nest).
    static let maxDepth = 48
    static let maxNodes = 1500

    /// The tree to draw, or nil when the root is missing (the message shows its text instead).
    public static func resolve(_ spec: UISpec, state: JSONValue) -> UINode? {
        var budget = maxNodes
        return node(spec.root, spec: spec, state: state, scope: UIScope(), ancestors: [], budget: &budget)
    }

    private static func node(_ key: String, spec: UISpec, state: JSONValue, scope: UIScope,
                             ancestors: [String], budget: inout Int) -> UINode? {
        // A child naming one of its ancestors is a cycle: drawn once, never again below itself.
        guard let element = spec.elements[key], !ancestors.contains(key), ancestors.count < maxDepth, budget > 0 else { return nil }
        let ctx = Context(state: state, scope: scope)
        if let visible = element.visible, !ctx.condition(visible) { return nil }
        budget -= 1
        let props = element.props.mapValues { ctx.value($0) }
        let id = key + (scope.basePath.map { "@" + $0 } ?? "")
        var valuePath: String?
        let kind = Self.kind(element.type, props: Props(props), raw: element.props, ctx: ctx, localPath: "/$local/" + id,
                             valuePath: &valuePath)
        var children: [UINode] = []
        let lineage = ancestors + [key]
        if let repeatPath = element.repeatPath, let path = ctx.repeatPath(repeatPath) {
            if case .array(let items)? = JSONPointer.get(state, path) {
                for (i, item) in items.enumerated() {
                    let itemScope = UIScope(item: item, index: i, basePath: JSONPointer.join(path, String(i)))
                    for child in element.children {
                        if let n = node(child, spec: spec, state: state, scope: itemScope, ancestors: lineage, budget: &budget) {
                            children.append(n)
                        }
                    }
                }
            }
        } else {
            children = element.children.compactMap { node($0, spec: spec, state: state, scope: scope, ancestors: lineage, budget: &budget) }
        }
        // Tabs whose panels don't say when they show: one panel per tab, in order.
        if case .tabs(let options, let selected) = kind, !element.children.isEmpty,
           element.children.allSatisfy({ spec.elements[$0]?.visible == nil }),
           let i = options.firstIndex(where: { $0.value == selected }) {
            children = i < children.count ? [children[i]] : []
        }
        return UINode(id: id, key: key, kind: kind, children: children, valuePath: valuePath, bindings: element.on, scope: scope)
    }

    private static func kind(_ type: String, props p: Props, raw: [String: JSONValue], ctx: Context, localPath: String,
                             valuePath: inout String?) -> UIKind {
        /// A choice's value: bound to the state (`$bindState`), else local.
        func choice(_ prop: String, initial: String?) -> String? {
            if case .object(let o)? = raw[prop], let path = o["$bindState"]?.stringValue ?? o["$bindItem"]?.stringValue.flatMap(ctx.itemPath) {
                valuePath = path
                return JSONPointer.get(ctx.state, path).flatMap(Props.text) ?? initial
            }
            valuePath = localPath
            return JSONPointer.get(ctx.state, localPath).flatMap(Props.text) ?? p.string(prop) ?? initial
        }
        switch type {
        case "Card":
            return .card(title: p.string("title"), description: p.string("description"))
        case "Stack":
            return .stack(axis: p.string("direction") == "horizontal" ? .horizontal : .vertical,
                          gap: p.gap("gap"), align: p.align("align"), justify: p.justify("justify"))
        case "Grid":
            return .grid(columns: min(max(p.int("columns") ?? 2, 1), 6), gap: p.gap("gap"))
        case "Separator":
            return .separator
        case "Heading":
            return .heading(p.string("text") ?? "")
        case "Text":
            let variants: [String: UITextVariant] = ["caption": .caption, "muted": .muted, "lead": .lead, "code": .code]
            return .text(p.string("text") ?? p.string("content") ?? "", variant: variants[p.string("variant") ?? ""] ?? .body)
        case "Badge":
            let variants: [String: UIBadgeVariant] = ["secondary": .secondary, "destructive": .destructive, "outline": .outline]
            return .badge(p.string("text") ?? p.string("label") ?? "", variant: variants[p.string("variant") ?? ""] ?? .default)
        case "Icon":
            let name = p.string("name") ?? ""
            let sizes: [String: UISize] = ["sm": .small, "lg": .large]
            let colors: [String: UIColorRole] = ["muted": .muted, "primary": .primary, "success": .success,
                                                 "warning": .warning, "danger": .danger, "destructive": .danger, "error": .danger]
            return .icon(name: name, symbol: LucideSymbols.symbol(for: name), size: sizes[p.string("size") ?? ""] ?? .medium,
                         color: colors[p.string("color") ?? ""] ?? .default)
        case "Image":
            let url = p.string("src").flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased()) ? $0 : nil }
            return .image(url: url, alt: p.string("alt") ?? "")
        case "Metric":
            let value = (p.string("prefix") ?? "") + (p.string("value") ?? "") + (p.string("suffix") ?? "")
            let change = p.string("change")
            var type: UIChange = switch p.string("changeType")?.lowercased() {
            case "positive", "increase", "up": .positive
            case "negative", "decrease", "down": .negative
            default: .neutral
            }
            if p.string("changeType") == nil, let c = change?.trimmingCharacters(in: .whitespaces).first {
                type = c == "+" ? .positive : (c == "-" || c == "−") ? .negative : .neutral
            }
            return .metric(UIMetric(label: p.string("label") ?? "", value: value, change: change, changeType: type))
        case "Progress":
            let max = p.double("max").flatMap { $0 > 0 ? $0 : nil } ?? 100
            return .progress(fraction: min(Swift.max((p.double("value") ?? 0) / max, 0), 1), label: p.string("label"))
        case "Alert":
            let types: [String: UIAlertType] = ["success": .success, "warning": .warning, "error": .error, "destructive": .error]
            return .alert(title: p.string("title") ?? "", message: p.string("message") ?? p.string("description"),
                          type: types[p.string("type") ?? p.string("variant") ?? ""] ?? .info)
        case "Table":
            let columns = p.strings("columns")
            return .table(columns: columns, rows: p.rows("rows", columns: columns), caption: p.string("caption"))
        case "BarGraph":
            return .barGraph(title: p.string("title"), data: p.dataPoints("data"))
        case "LineGraph":
            return .lineGraph(title: p.string("title"), data: p.dataPoints("data"))
        case "Button":
            let variants: [String: UIButtonVariant] = ["primary": .primary, "danger": .danger, "destructive": .danger]
            return .button(label: p.string("label") ?? p.string("text") ?? "", variant: variants[p.string("variant") ?? ""] ?? .secondary,
                           disabled: p.bool("disabled") ?? false)
        case "ButtonGroup":
            let options = p.options("buttons")
            return .buttonGroup(options: options, selected: choice("selected", initial: nil))
        case "Select":
            let options = p.options("options")
            return .select(label: p.string("label") ?? "", options: options, value: choice("value", initial: nil))
        case "Tabs":
            let options = p.options("tabs")
            let selected = choice("value", initial: p.string("defaultValue") ?? options.first?.value)
            return .tabs(options: options, selected: selected)
        default:
            return .unknown(type)
        }
    }

    // MARK: Actions

    /// What `event` does on `node`, its params read against `state` now (after a choice wrote
    /// its value). A choice that replies without `text` replies with its label.
    public static func actions(_ event: String, of node: UINode, state: JSONValue, choice: UIOption? = nil) -> [DynamicUIAction] {
        var bindings = node.bindings[event] ?? []
        // A choice's "change" and "press" are the same gesture (§8: a button group's choices answer).
        if bindings.isEmpty, choice != nil { bindings = node.bindings[event == "change" ? "press" : "change"] ?? [] }
        let ctx = Context(state: state, scope: node.scope)
        return bindings.map { b in
            switch b.action {
            case "reply":
                let text = b.params["text"].map(ctx.value).flatMap(Props.text) ?? choice?.label
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unknown("reply without text") }
                return .reply(text)
            case "open":
                guard let s = b.params["url"].map(ctx.value).flatMap(Props.text), let url = URL(string: s),
                      ["https", "http"].contains(url.scheme?.lowercased()) else { return .unknown("open without an http(s) url") }
                return .open(url)
            case "setState":
                let path: String? = switch b.params["statePath"] {
                case .string(let s)?: s
                case .object(let o)?: o["$item"]?.stringValue.flatMap(ctx.itemPath) ?? o["$state"]?.stringValue
                default: nil
                }
                guard let path else { return .unknown("setState without statePath") }
                return .setState(path: path, value: b.params["value"].map(ctx.value) ?? .null)
            default:
                return .unknown(b.action)
            }
        }
    }
}

// MARK: - Expressions and conditions

/// json-render's prop expressions (packages/core/src/props.ts) and visibility conditions
/// (visibility.ts), against the state and the repeat scope.
struct Context {
    let state: JSONValue
    let scope: UIScope

    func value(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            if let p = o["$state"]?.stringValue { return JSONPointer.get(state, p) ?? .null }
            if let p = o["$bindState"]?.stringValue { return JSONPointer.get(state, p) ?? .null }
            if let p = o["$item"]?.stringValue { return item(p) ?? .null }
            if let p = o["$bindItem"]?.stringValue { return item(p) ?? .null }
            if o["$index"] == .bool(true) { return scope.index.map { .number(Double($0)) } ?? .null }
            if let c = o["$cond"], o["$then"] != nil || o["$else"] != nil {
                return value(condition(c) ? (o["$then"] ?? .null) : (o["$else"] ?? .null))
            }
            if let t = o["$template"]?.stringValue { return .string(template(t)) }
            return .object(o.mapValues(value))
        case .array(let a):
            return .array(a.map(value))
        default:
            return v
        }
    }

    private func item(_ path: String) -> JSONValue? {
        guard let item = scope.item else { return nil }
        return path.isEmpty || path == "/" ? item : JSONPointer.get(item, path.hasPrefix("/") ? path : "/" + path)
    }

    /// `$item`/`$bindItem` as an absolute state path.
    func itemPath(_ field: String) -> String? {
        guard let base = scope.basePath else { return nil }
        return field.isEmpty || field == "/" ? base : JSONPointer.join(base, field)
    }

    func repeatPath(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): s
        case .object(let o): o["$item"]?.stringValue.flatMap(itemPath)
        default: nil
        }
    }

    /// `${/abs/path}` from the state; `${field}` from the repeat item, else the state's root.
    func template(_ t: String) -> String {
        var out = ""
        var rest = Substring(t)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out += rest[..<open.lowerBound]
            let path = String(rest[open.upperBound..<close])
            let found: JSONValue? = path.hasPrefix("/") ? JSONPointer.get(state, path)
                : (item(path).flatMap { $0 == .null ? nil : $0 } ?? JSONPointer.get(state, "/" + path))
            out += found.flatMap(Props.text) ?? ""
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// json-render's VisibilityCondition, plus the older `and`/`or`/`not` and `{"eq": [a, b]}`
    /// forms models still write.
    func condition(_ c: JSONValue) -> Bool {
        switch c {
        case .bool(let b): return b
        case .null: return true
        case .array(let all): return all.allSatisfy(condition)
        case .object(let o):
            if case .array(let all)? = o["$and"] ?? o["and"] { return all.allSatisfy(condition) }
            if case .array(let any)? = o["$or"] ?? o["or"] { return any.contains(where: condition) }
            if let inner = o["not"], case .object = inner { return !condition(inner) }
            let subject: JSONValue?
            if let p = o["$state"]?.stringValue { subject = JSONPointer.get(state, p) ?? .null }
            else if let p = o["$item"]?.stringValue { subject = item(p) ?? .null }
            else if o["$index"] == .bool(true) { subject = scope.index.map { .number(Double($0)) } ?? .null }
            else { subject = nil }
            var result: Bool
            if let subject {
                result = compare(subject, o)
            } else if let op = ["eq", "neq", "gt", "gte", "lt", "lte"].first(where: { op in
                if case .array(let a)? = o[op], a.count == 2 { true } else { false }
            }), case .array(let pair)? = o[op] {
                result = compare(value(pair[0]), [op: pair[1]])
            } else {
                return true
            }
            if o["not"] == .bool(true) { result.toggle() }
            return result
        default:
            return Props.truthy(c)
        }
    }

    private func compare(_ subject: JSONValue, _ o: [String: JSONValue]) -> Bool {
        if let v = o["eq"] { return Props.equal(subject, value(v)) }
        if let v = o["neq"] { return !Props.equal(subject, value(v)) }
        for (op, test) in [("gt", { (a: Double, b: Double) in a > b }), ("gte", { $0 >= $1 }), ("lt", { $0 < $1 }), ("lte", { $0 <= $1 })] {
            if let v = o[op] {
                guard let a = Props.number(subject), let b = Props.number(value(v)) else { return false }
                return test(a, b)
            }
        }
        return Props.truthy(subject)
    }
}

// MARK: - Lenient props

/// Reads resolved props, taking a wrong type where it can (a number for a string, "65" for 65).
struct Props {
    let values: [String: JSONValue]
    init(_ values: [String: JSONValue]) { self.values = values }

    static func text(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): s
        case .number(let n): format(n)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }

    /// As JavaScript's `String(n)`: no ".0" on whole numbers.
    static func format(_ n: Double) -> String {
        if n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    static func number(_ v: JSONValue) -> Double? {
        switch v {
        case .number(let n): n
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    static func truthy(_ v: JSONValue) -> Bool {
        switch v {
        case .null: false
        case .bool(let b): b
        case .number(let n): n != 0 && !n.isNaN
        case .string(let s): !s.isEmpty
        case .array, .object: true
        }
    }

    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool { a == b }

    func string(_ key: String) -> String? { values[key].flatMap(Self.text) }
    func double(_ key: String) -> Double? { values[key].flatMap(Self.number) }
    func int(_ key: String) -> Int? { double(key).map { Int($0) } }

    func bool(_ key: String) -> Bool? {
        switch values[key] {
        case .bool(let b)?: b
        case .string(let s)?: s == "true"
        case .number(let n)?: n != 0
        default: nil
        }
    }

    func strings(_ key: String) -> [String] {
        guard case .array(let a)? = values[key] else { return [] }
        return a.compactMap { v in
            if case .object(let o) = v { return o["label"].flatMap(Self.text) ?? o["title"].flatMap(Self.text) }
            return Self.text(v)
        }
    }

    /// `[{label, value}]`, or plain strings (each its own value).
    func options(_ key: String) -> [UIOption] {
        guard case .array(let a)? = values[key] else { return [] }
        var seen: Set<String> = []
        return a.compactMap { v -> UIOption? in
            let option: UIOption?
            if case .object(let o) = v {
                let label = o["label"].flatMap(Self.text) ?? o["value"].flatMap(Self.text)
                option = label.map { UIOption(label: $0, value: o["value"].flatMap(Self.text) ?? $0) }
            } else {
                option = Self.text(v).map { UIOption(label: $0, value: $0) }
            }
            guard let option, seen.insert(option.value).inserted else { return nil }
            return option
        }
    }

    /// Rows as arrays of cells; a row written as an object is read by the column names.
    func rows(_ key: String, columns: [String]) -> [[String]] {
        guard case .array(let a)? = values[key] else { return [] }
        return a.compactMap { row in
            switch row {
            case .array(let cells): return cells.map { Self.text($0) ?? "" }
            case .object(let o):
                return columns.map { c in (o[c] ?? o[c.lowercased()]).flatMap(Self.text) ?? "" }
            default: return nil
            }
        }
    }

    /// `[{label, value}]` (also `name`/`x` and `y`), points without a number dropped.
    func dataPoints(_ key: String) -> [UIDataPoint] {
        guard case .array(let a)? = values[key] else { return [] }
        return a.enumerated().compactMap { i, v in
            guard case .object(let o) = v, let value = (o["value"] ?? o["y"]).flatMap(Self.number), value.isFinite else { return nil }
            let label = (o["label"] ?? o["name"] ?? o["x"]).flatMap(Self.text) ?? String(i + 1)
            return UIDataPoint(id: i, label: label, value: value)
        }
    }

    func gap(_ key: String) -> UIGap {
        switch string(key) {
        case "none": .none
        case "sm": .small
        case "lg": .large
        case "xl": .extraLarge
        default: .medium
        }
    }

    func align(_ key: String) -> UIAlign {
        switch string(key) {
        case "center": .center
        case "end": .end
        case "stretch": .stretch
        default: .start
        }
    }

    func justify(_ key: String) -> UIJustify {
        switch string(key) {
        case "center": .center
        case "end": .end
        case "between": .between
        case "around": .around
        default: .start
        }
    }
}

// MARK: - JSON Pointer (RFC 6901)

public enum JSONPointer {
    static func segments(_ path: String) -> [String] {
        guard !path.isEmpty, path != "/" else { return [] }
        let body = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return body.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
    }

    static func join(_ base: String, _ child: String) -> String {
        let c = child.hasPrefix("/") ? String(child.dropFirst()) : child
        return base.isEmpty || base == "/" ? "/" + c : base + "/" + c
    }

    public static func get(_ root: JSONValue, _ path: String) -> JSONValue? {
        var current = root
        for s in segments(path) {
            switch current {
            case .object(let o):
                guard let next = o[s] else { return nil }
                current = next
            case .array(let a):
                guard let i = Int(s), a.indices.contains(i) else { return nil }
                current = a[i]
            default:
                return nil
            }
        }
        return current
    }

    /// `root` with `value` at `path`, creating the objects on the way (json-render's setByPath).
    public static func set(_ root: JSONValue, _ path: String, _ value: JSONValue) -> JSONValue {
        set(root, segments(path)[...], value)
    }

    private static func set(_ node: JSONValue, _ path: ArraySlice<String>, _ value: JSONValue) -> JSONValue {
        guard let head = path.first else { return value }
        let rest = path.dropFirst()
        switch node {
        case .array(var a):
            if head == "-" { a.append(set(.null, rest, value)); return .array(a) }
            guard let i = Int(head), i >= 0, i <= a.count else { return node }
            if i == a.count { a.append(set(.null, rest, value)) } else { a[i] = set(a[i], rest, value) }
            return .array(a)
        case .object(var o):
            o[head] = set(o[head] ?? .null, rest, value)
            return .object(o)
        default:
            return .object([head: set(.null, rest, value)])
        }
    }
}
