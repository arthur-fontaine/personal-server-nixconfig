import Foundation

/// `controls` slot (protocol §2.4): the curated commands and the values they set. The app sets
/// anything by sending the slash command, as the owner, in the chat it applies to.
public struct ControlsState: Sendable, Equatable {
    public var permissionMode: PermissionModeControl?
    public var model: ModelControl?
    public var presets: [PresetInfo]
    public var commands: [CommandSpec]

    public init(permissionMode: PermissionModeControl? = nil, model: ModelControl? = nil,
                presets: [PresetInfo] = [], commands: [CommandSpec] = []) {
        self.permissionMode = permissionMode
        self.model = model
        self.presets = presets
        self.commands = commands
    }

    init(fields: [String: JSONValue]) {
        permissionMode = fields.decode(PermissionModeControl.self, key: "permission_mode")
        model = fields.decode(ModelControl.self, key: "model")
        presets = fields.decodeArray(PresetInfo.self, key: "presets")
        commands = fields.decodeArray(CommandSpec.self, key: "commands")
    }

    /// The commands that apply in this chat, in the palette's order.
    public func commands(for context: CommandContext) -> [CommandSpec] {
        commands.filter { $0.applies(in: context) && ($0.id != "permissions" || permissionMode?.set != nil) }
            .sorted { CommandCatalog.order($0.id) < CommandCatalog.order($1.id) }
    }

    /// Presets with the default one first (the form's initial choice).
    public var orderedPresets: [PresetInfo] { presets.filter(\.isDefault) + presets.filter { !$0.isDefault } }
}

/// Where the palette is opened.
public struct CommandContext: Sendable, Equatable {
    public var topic: TopicID
    public var isEncrypted: Bool
    public var isUnlocked: Bool

    public init(topic: TopicID, isEncrypted: Bool = false, isUnlocked: Bool = false) {
        self.topic = topic
        self.isEncrypted = isEncrypted
        self.isUnlocked = isUnlocked
    }
}

public struct CommandSpec: Sendable, Codable, Equatable, Identifiable {
    public enum Where: String, Sendable, Codable { case any, main, subchat, encrypted }

    public var id: String
    public var send: String?
    public var insert: String?
    public var where_: Where
    public var control: String?
    public var options: [String]
    public var confirm: String?

    public init(id: String, send: String? = nil, insert: String? = nil, where_: Where = .any, control: String? = nil,
                options: [String] = [], confirm: String? = nil) {
        self.id = id
        self.send = send
        self.insert = insert
        self.where_ = where_
        self.control = control
        self.options = options
        self.confirm = confirm
    }

    enum CodingKeys: String, CodingKey { case id, send, insert, where_ = "where", control, options, confirm }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        send = try? c.decodeIfPresent(String.self, forKey: .send)
        insert = try? c.decodeIfPresent(String.self, forKey: .insert)
        where_ = (try? c.decode(String.self, forKey: .where_)).flatMap(Where.init(rawValue:)) ?? .any
        control = try? c.decodeIfPresent(String.self, forKey: .control)
        // Options are strings, or {id,label} objects.
        if let strings = try? c.decode([String].self, forKey: .options) { options = strings }
        else if let objects = try? c.decode([[String: String]].self, forKey: .options) { options = objects.compactMap { $0["id"] } }
        else { options = [] }
        confirm = try? c.decodeIfPresent(String.self, forKey: .confirm)
    }

    public func applies(in ctx: CommandContext) -> Bool {
        switch where_ {
        case .any: true
        case .main: ctx.topic == .main
        case .subchat: ctx.topic != .main
        case .encrypted: ctx.topic != .main && ctx.isEncrypted && ctx.isUnlocked
        }
    }

    public var label: String { CommandCatalog.entry(id).label }
    public var symbol: String { CommandCatalog.entry(id).symbol }
    public var detail: String { CommandCatalog.entry(id).detail }

    /// The text to send, with `{value}`, `{model}`… filled.
    public func text(_ values: [String: String] = [:]) -> String? {
        (send ?? insert).map { CommandTemplate.fill($0, values) }
    }
}

public enum CommandTemplate {
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (k, v) in values { out = out.replacingOccurrences(of: "{\(k)}", with: v) }
        return out
    }
}

/// Labels, icons and one-line descriptions of the curated commands (protocol §2.4's table).
public enum CommandCatalog {
    public struct Entry: Sendable {
        public let label: String
        public let symbol: String
        public let detail: String
    }

    static let ids = ["model", "permissions", "reasoning", "sub.new", "btw", "bg", "goal", "retry", "undo", "agents", "status",
                      "usage", "stop", "sub.show", "sub.set", "sub.lock", "sub.end", "pause", "resume"]

    static func order(_ id: String) -> Int { ids.firstIndex(of: id) ?? ids.count }

    public static func entry(_ id: String) -> Entry {
        switch id {
        case "stop": Entry(label: L("Stop background work"), symbol: "stop.circle", detail: L("Kill the background processes"))
        case "retry": Entry(label: L("Retry"), symbol: "arrow.clockwise", detail: L("Send your last message again"))
        case "undo": Entry(label: L("Undo last turn"), symbol: "arrow.uturn.backward", detail: L("Back up one turn"))
        case "btw": Entry(label: L("Side question"), symbol: "bubble.left.and.text.bubble.right", detail: L("Ask without interrupting the turn"))
        case "bg": Entry(label: L("Run in background"), symbol: "square.stack.3d.down.right", detail: L("A prompt in a separate background session"))
        case "goal": Entry(label: L("Standing goal"), symbol: "scope", detail: L("Hermes works on it across turns until reached"))
        case "agents": Entry(label: L("Running tasks"), symbol: "list.bullet.rectangle", detail: L("The agents and tasks running now"))
        case "status": Entry(label: L("Session status"), symbol: "info.circle", detail: L("Model, tokens and context"))
        case "usage": Entry(label: L("Usage and limits"), symbol: "chart.bar", detail: L("Token usage and rate limits"))
        case "reasoning": Entry(label: L("Reasoning effort"), symbol: "brain", detail: L("How hard the model thinks"))
        case "model": Entry(label: L("Model"), symbol: "cpu", detail: L("Which model answers in this chat"))
        case "permissions": Entry(label: L("Permission mode"), symbol: "checkmark.shield", detail: L("What Hermes may do without asking"))
        case "sub.new": Entry(label: L("New sub-chat"), symbol: "plus.bubble", detail: L("A topic with its own memory and rules"))
        case "sub.show": Entry(label: L("Sub-chat rules"), symbol: "list.bullet.clipboard", detail: L("This sub-chat's policy"))
        case "sub.set": Entry(label: L("Change a rule"), symbol: "slider.horizontal.3", detail: L("Memory, tools, expiry, model…"))
        case "sub.lock": Entry(label: L("Lock"), symbol: "lock", detail: L("Forget this sub-chat's key until unlocked"))
        case "sub.end": Entry(label: L("End sub-chat"), symbol: "trash", detail: L("Delete the topic and its memory"))
        case "pause": Entry(label: L("Emergency stop"), symbol: "exclamationmark.octagon", detail: L("No new work until resumed"))
        case "resume": Entry(label: L("Resume work"), symbol: "play.circle", detail: L("Lift the emergency stop"))
        default: Entry(label: id, symbol: "command", detail: "")
        }
    }
}

public struct PermissionModeControl: Sendable, Codable, Equatable {
    public struct Option: Sendable, Codable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var description: String?
        public init(id: String, label: String, description: String? = nil) {
            self.id = id
            self.label = label
            self.description = description
        }
    }

    public var value: String?
    public var set: String?
    public var options: [Option]

    public init(value: String?, set: String?, options: [Option]) {
        self.value = value
        self.set = set
        self.options = options
    }

    public func command(for option: String) -> String? { set.map { CommandTemplate.fill($0, ["value": option]) } }
}

public struct ModelRef: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var provider: String
    public var model: String
    public var role: String?
    public var at: Date?

    public var id: String { "\(provider):\(model)" }

    public init(provider: String, model: String, role: String? = nil, at: Date? = nil) {
        self.provider = provider
        self.model = model
        self.role = role
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case provider, model, role, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
        model = try c.decode(String.self, forKey: .model)
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        at = c.decodeFlexibleDate(.at)
    }

    public static func == (a: ModelRef, b: ModelRef) -> Bool { a.provider == b.provider && a.model == b.model }
    public func hash(into h: inout Hasher) { h.combine(provider); h.combine(model) }
}

public struct ModelControl: Sendable, Codable, Equatable {
    public var chain: [ModelRef]
    public var defaultModel: ModelRef?
    public var current: [TopicID: ModelRef]
    public var last: [TopicID: ModelRef]
    public var setMain: String?
    public var setSubchat: String?

    public init(chain: [ModelRef], defaultModel: ModelRef?, current: [TopicID: ModelRef] = [:], last: [TopicID: ModelRef] = [:],
                setMain: String?, setSubchat: String?) {
        self.chain = chain
        self.defaultModel = defaultModel
        self.current = current
        self.last = last
        self.setMain = setMain
        self.setSubchat = setSubchat
    }

    enum CodingKeys: String, CodingKey { case chain, defaultModel = "default", current, last, setMain = "set_main", setSubchat = "set_subchat" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chain = (try? c.decode([ModelRef].self, forKey: .chain)) ?? []
        defaultModel = try? c.decodeIfPresent(ModelRef.self, forKey: .defaultModel)
        func byChat(_ key: CodingKeys) -> [TopicID: ModelRef] {
            let raw = (try? c.decode([String: ModelRef].self, forKey: key)) ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in TopicID(k).map { ($0, v) } })
        }
        current = byChat(.current)
        last = byChat(.last)
        setMain = try? c.decodeIfPresent(String.self, forKey: .setMain)
        setSubchat = try? c.decodeIfPresent(String.self, forKey: .setSubchat)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chain, forKey: .chain)
    }

    /// What answers in this chat now: a switch in force, else the default.
    public func selected(in topic: TopicID) -> ModelRef? { current[topic] ?? defaultModel }

    public func command(for model: ModelRef, in topic: TopicID) -> String? {
        let template = topic == .main ? setMain : setSubchat
        return template.map { CommandTemplate.fill($0, ["model": model.model, "provider": model.provider]) }
    }
}

public struct PresetInfo: Sendable, Codable, Equatable, Identifiable {
    public var name: String
    public var isDefault: Bool
    public var encrypted: Bool
    public var ttl: String?
    public var model: String?
    public var memoryRead: Bool?
    public var memoryWrite: Bool?

    public var id: String { name }

    public init(name: String, isDefault: Bool = false, encrypted: Bool = false, ttl: String? = nil, model: String? = nil,
                memoryRead: Bool? = nil, memoryWrite: Bool? = nil) {
        self.name = name
        self.isDefault = isDefault
        self.encrypted = encrypted
        self.ttl = ttl
        self.model = model
        self.memoryRead = memoryRead
        self.memoryWrite = memoryWrite
    }

    enum CodingKeys: String, CodingKey { case name, isDefault = "default", encrypted, ttl, model, memoryRead, memoryWrite }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        encrypted = (try? c.decode(Bool.self, forKey: .encrypted)) ?? false
        ttl = try? c.decodeIfPresent(String.self, forKey: .ttl)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        memoryRead = try? c.decodeIfPresent(Bool.self, forKey: .memoryRead)
        memoryWrite = try? c.decodeIfPresent(Bool.self, forKey: .memoryWrite)
    }

    /// One line built from the rules, for presets the app has no blurb for.
    public var summary: String {
        var parts: [String] = []
        if encrypted { parts.append("encrypted") }
        if memoryRead == true { parts.append("reads your memory") } else if memoryRead == false { parts.append("no main memory") }
        if let ttl { parts.append(ttl == "session" ? "gone when its session ends" : "expires after \(ttl)") }
        if let model { parts.append("model \(model)") }
        return parts.joined(separator: ", ").capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
