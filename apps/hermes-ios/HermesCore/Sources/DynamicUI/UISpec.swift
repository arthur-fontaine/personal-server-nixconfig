import Foundation

// A dynamic UI Hermes sends with a message (docs/app-protocol.md §8): json-render's flat spec
// (https://json-render.dev, vercel-labs/json-render packages/core/src/types.ts), decoded leniently:
// unknown keys are ignored, a wrong type falls back, and only a spec without a root or elements
// fails (the message then shows its text).

/// `{root, elements, state?}`, kept as the JSON it came as so it persists unchanged.
public struct UISpec: Sendable, Equatable, Codable {
    public let root: String
    public let elements: [String: UIElement]
    /// The initial state: always an object.
    public let state: JSONValue
    public let source: JSONValue

    public init?(json: JSONValue) {
        guard case .object(let fields) = json, case .string(let root)? = fields["root"],
              case .object(let raw)? = fields["elements"], !raw.isEmpty else { return nil }
        self.root = root
        elements = raw.compactMapValues(UIElement.init(json:))
        if case .object? = fields["state"] { state = fields["state"]! } else { state = .object([:]) }
        source = json
    }

    public static func decode(_ data: Data) -> UISpec? {
        (try? JSONDecoder().decode(JSONValue.self, from: data)).flatMap(UISpec.init(json:))
    }

    public init(from decoder: Decoder) throws {
        let json = try JSONValue(from: decoder)
        guard let spec = UISpec(json: json) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a json-render spec"))
        }
        self = spec
    }

    public func encode(to encoder: Encoder) throws { try source.encode(to: encoder) }

    /// Whether the app can draw it: its root exists and resolves to something.
    public var isRenderable: Bool { DynamicUI.resolve(self, state: state) != nil }
}

public struct UIElement: Sendable, Equatable {
    public var type: String
    public var props: [String: JSONValue]
    public var children: [String]
    public var visible: JSONValue?
    /// Event → actions (json-render allows one binding or a list).
    public var on: [String: [UIActionBinding]]
    /// `repeat.statePath`: a pointer, or `{"$item": field}` inside another repeat.
    public var repeatPath: JSONValue?

    init?(json: JSONValue) {
        guard case .object(let f) = json else { return nil }
        type = f["type"]?.stringValue ?? ""
        if case .object(let p)? = f["props"] { props = p } else { props = [:] }
        if case .array(let c)? = f["children"] { children = c.compactMap(\.stringValue) } else { children = [] }
        visible = f["visible"]
        var on: [String: [UIActionBinding]] = [:]
        if case .object(let events)? = f["on"] {
            for (event, value) in events {
                let list: [JSONValue] = if case .array(let a) = value { a } else { [value] }
                let bindings = list.compactMap(UIActionBinding.init(json:))
                if !bindings.isEmpty { on[event] = bindings }
            }
        }
        self.on = on
        if case .object(let r)? = f["repeat"] { repeatPath = r["statePath"] } else { repeatPath = nil }
    }
}

public struct UIActionBinding: Sendable, Equatable {
    public var action: String
    public var params: [String: JSONValue]

    init?(json: JSONValue) {
        guard case .object(let f) = json, case .string(let action)? = f["action"] else { return nil }
        self.action = action
        if case .object(let p)? = f["params"] { params = p } else { params = [:] }
    }
}

/// What a press or a choice does (§8 "Actions"). Everything else is `unknown`: logged, no effect.
public enum DynamicUIAction: Sendable, Equatable {
    /// Send this text as the owner's reply to the UI's message.
    case reply(String)
    /// Open an http(s) link.
    case open(URL)
    /// Write the UI's local state.
    case setState(path: String, value: JSONValue)
    case unknown(String)
}

/// The `ui` App-topic message: the spec (inline), or a `ui.json` document to download (`file`).
public struct UIEnvelope: Sendable, Equatable {
    public var chat: TopicID
    /// The text message it belongs to, as the protocol numbers it (Bot API).
    public var messageID: MessageID
    public var spec: UISpec?
    public var isFile: Bool

    init?(fields: [String: JSONValue]) {
        guard case .number(let id)? = fields["message_id"] else { return nil }
        messageID = MessageID(id)
        if case .number(let c)? = fields["chat"] { chat = TopicID(c) } else { chat = .main }
        spec = fields["spec"].flatMap(UISpec.init(json:))
        isFile = fields["file"] == .bool(true)
    }
}
