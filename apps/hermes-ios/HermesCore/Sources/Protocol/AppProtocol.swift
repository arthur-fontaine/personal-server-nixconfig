import Foundation

/// The machine-readable traffic in the hidden "App" topic (hermes-app-work/app-protocol.md).
/// Each message is one JSON object in a ```json block, with `v` and `type`.
public enum AppProtocol {
    public static let version = 2
    public static let topicName = "App"

    /// Pulls the JSON object out of a message: the content of the first ```json fence, else the
    /// whole text when it is a bare object.
    public static func extractJSON(from text: String) -> Data? {
        if let fence = text.range(of: "```") {
            var rest = text[fence.upperBound...]
            if let newline = rest.firstIndex(of: "\n") {
                let lang = rest[..<newline].trimmingCharacters(in: .whitespaces)
                if lang.isEmpty || lang.lowercased() == "json" { rest = rest[rest.index(after: newline)...] }
            }
            guard let close = rest.range(of: "```") else { return nil }
            return Data(rest[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        return Data(trimmed.utf8)
    }

    public static func decode(_ text: String) -> AppMessage? {
        guard let data = extractJSON(from: text),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = object,
              case .string(let type)? = fields["type"] else { return nil }
        switch type {
        case "state": return .state(AppState(fields: fields))
        case "stats": return fields.decode(StatsState.self).map(AppMessage.stats)
        case "devices": return .devices(DeliveryState(fields: fields))
        case "controls": return .controls(ControlsState(fields: fields))
        case "notify": return fields.decode(NotifyPayload.self).map(AppMessage.notify)
        case "reply": return .reply(ReplyPayload(fields: fields))
        default: return .other(type: type, fields: fields)
        }
    }

    /// The text of a request message: a ```json block, readable in the official app too.
    public static func encode(_ request: AppRequest) -> String {
        var fields = request.payload
        fields["v"] = .number(Double(version))
        fields["type"] = .string(request.type)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(JSONValue.object(fields))) ?? Data("{}".utf8)
        return "```json\n" + String(decoding: data, as: UTF8.self) + "\n```"
    }
}

public enum AppMessage: Sendable {
    case state(AppState)
    case stats(StatsState)
    case devices(DeliveryState)
    case controls(ControlsState)
    case notify(NotifyPayload)
    case reply(ReplyPayload)
    case other(type: String, fields: [String: JSONValue])
}

// MARK: - Requests (app → bot)

public struct AppRequest: Sendable, Equatable {
    public var type: String
    public var payload: [String: JSONValue]

    public init(type: String, payload: [String: JSONValue] = [:]) {
        self.type = type
        self.payload = payload
    }

    public static let statsRefresh = AppRequest(type: "stats.refresh")
    public static let petFeed = AppRequest(type: "pet.feed")
    public static let petPlay = AppRequest(type: "pet.play")
    public static let petSleep = AppRequest(type: "pet.sleep")
    public static let petWake = AppRequest(type: "pet.wake")
    public static let appReinstall = AppRequest(type: "app.reinstall")
    /// While on, Hermes answers every owner turn in its spoken style (protocol §6).
    public static func callState(active: Bool) -> AppRequest {
        AppRequest(type: "call.state", payload: ["active": .bool(active)])
    }
    public static func petGenerate(prompt: String) -> AppRequest {
        AppRequest(type: "pet.generate", payload: ["prompt": .string(prompt)])
    }
    public static func ack(_ messageIDs: [MessageID]) -> AppRequest {
        AppRequest(type: "ack", payload: ["ids": .array(messageIDs.map { .number(Double($0)) })])
    }
    public static func hello(appVersion: String, build: String, device: String, petVersion: Int?) -> AppRequest {
        var payload: [String: JSONValue] = ["app_version": .string(appVersion), "build": .string(build), "device": .string(device)]
        if let petVersion { payload["pet_version"] = .number(Double(petVersion)) }
        return AppRequest(type: "hello", payload: payload)
    }
    public static func pushUnregister(token: Data) -> AppRequest {
        AppRequest(type: "push.unregister", payload: ["token_hex": .string(token.map { String(format: "%02x", $0) }.joined())])
    }
    /// Only with a paid team: Hermes sends APNs itself (Telegram cannot push to our bundle id).
    public static func pushRegister(token: Data, kind: String, sandbox: Bool, bundleID: String) -> AppRequest {
        AppRequest(type: "push.register", payload: [
            "token_hex": .string(token.map { String(format: "%02x", $0) }.joined()),
            "kind": .string(kind),
            "sandbox": .bool(sandbox),
            "bundle_id": .string(bundleID),
        ])
    }
}

// MARK: - State (bot → app, the pinned message the bot edits)

public struct AppState: Sendable, Equatable {
    public var agent: AgentState?
    /// Every open question, oldest first.
    public var questions: [PendingQuestion]
    public var pet: PetState?
    public var subchats: [SubchatInfo]
    /// Message ids of the other slot messages (`stats`, `devices`, `sprite`).
    public var slots: [String: MessageID]
    public var updatedAt: Date?

    public init(agent: AgentState? = nil, questions: [PendingQuestion] = [], pet: PetState? = nil,
                subchats: [SubchatInfo] = [], slots: [String: MessageID] = [:], updatedAt: Date? = nil) {
        self.agent = agent
        self.questions = questions
        self.pet = pet
        self.subchats = subchats
        self.slots = slots
        self.updatedAt = updatedAt
    }

    /// Each section decodes on its own: a section the app does not understand is dropped, not the state.
    init(fields: [String: JSONValue]) {
        agent = fields.decode(AgentState.self, key: "agent")
        questions = fields.decodeArray(PendingQuestion.self, key: "questions")
        if questions.isEmpty, let single = fields.decode(PendingQuestion.self, key: "question") { questions = [single] }
        pet = fields.decode(PetState.self, key: "pet")
        subchats = fields.decodeArray(SubchatInfo.self, key: "subchats")
        var slots: [String: MessageID] = [:]
        if case .object(let o)? = fields["slots"] {
            for (k, v) in o { if case .number(let n) = v { slots[k] = MessageID(n) } }
        }
        self.slots = slots
        updatedAt = fields.decode(FlexibleDate.self, key: "updated_at")?.date
    }

    /// The question to surface first (Live Activity, banner): the oldest.
    public var question: PendingQuestion? { questions.first }
}

/// `devices` slot: the sideload service's delivery.json for the app `hermes`, under `delivery`.
public struct DeliveryState: Sendable, Equatable {
    public var teamPaid: Bool?
    public var devices: [DeviceInfo]
    public var nextRefresh: Date?

    public init(teamPaid: Bool? = nil, devices: [DeviceInfo] = [], nextRefresh: Date? = nil) {
        self.teamPaid = teamPaid
        self.devices = devices
        self.nextRefresh = nextRefresh
    }

    init(fields: [String: JSONValue]) {
        guard case .object(let delivery)? = fields["delivery"] else { self.init(); return }
        var paid: Bool?
        if case .object(let team)? = delivery["team"], case .bool(let b)? = team["paid"] { paid = b }
        self.init(teamPaid: paid, devices: delivery.decodeArray(DeviceInfo.self, key: "devices"),
                  nextRefresh: delivery.decode(FlexibleDate.self, key: "next_refresh")?.date)
    }
}

struct FlexibleDate: Decodable {
    let date: Date
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { date = Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d); return }
        let s = try c.decode(String.self)
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { date = d; return }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: s) else { throw DecodingError.dataCorruptedError(in: c, debugDescription: s) }
        date = d
    }
}

public enum AgentStatus: String, Sendable, Codable, CaseIterable {
    case idle, thinking, working
    case waitingUser = "waiting_user"
    case error

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? (raw == "waiting" ? .waitingUser : .idle)
    }

    public var isBusy: Bool { self == .thinking || self == .working }

    public var label: String {
        switch self {
        case .idle: L("Idle")
        case .thinking: L("Thinking")
        case .working: L("Working")
        case .waitingUser: L("Needs you")
        case .error: L("Error")
        }
    }
}

public struct AgentState: Sendable, Codable, Equatable {
    public var status: AgentStatus
    public var task: String?
    public var since: Date?
    public var chat: TopicID?
    public var progress: String?
    public var busyChats: [TopicID]

    public init(status: AgentStatus, task: String? = nil, since: Date? = nil, chat: TopicID? = nil, progress: String? = nil, busyChats: [TopicID] = []) {
        self.status = status
        self.task = task
        self.since = since
        self.chat = chat
        self.progress = progress
        self.busyChats = busyChats
    }

    enum CodingKeys: String, CodingKey { case status, task, since, chat, progress, busyChats = "busy_chats" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decode(AgentStatus.self, forKey: .status)) ?? .idle
        task = try? c.decodeIfPresent(String.self, forKey: .task)
        since = c.decodeFlexibleDate(.since)
        chat = c.decodeTopic(.chat)
        progress = try? c.decodeIfPresent(String.self, forKey: .progress)
        busyChats = ((try? c.decode([Int64].self, forKey: .busyChats)) ?? []).map { TopicID(truncatingIfNeeded: $0) }
    }
}

public struct QuestionOption: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    /// The button's callback data, when the backend sends it (`data_b64`); otherwise the app
    /// finds the button with the same label in the message's inline keyboard.
    public var data: Data?

    public init(id: String, label: String, data: Data? = nil) {
        self.id = id
        self.label = label
        self.data = data
    }

    enum CodingKeys: String, CodingKey { case id, label, data = "data_b64" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? "?"
        id = (try? c.decode(String.self, forKey: .id)) ?? label
        data = (try? c.decodeIfPresent(String.self, forKey: .data)).flatMap { Data(base64Encoded: $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(data?.base64EncodedString(), forKey: .data)
    }

    /// Deny-like options get the destructive style.
    public var isDestructive: Bool {
        let l = label.lowercased()
        return ["deny", "refuser", "non", "no", "reject", "cancel", "annuler"].contains { l.hasPrefix($0) }
    }
}

public struct PendingQuestion: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case approval, clarify, proposal, question
    }

    public var id: String
    public var kind: Kind
    public var chat: TopicID
    public var messageID: MessageID?
    public var text: String
    public var spoken: String?
    /// For approvals: the backend's plain-language summary of the command…
    public var summary: String?
    /// …and the raw command, shown collapsed.
    public var command: String?
    public var options: [QuestionOption]
    public var askedAt: Date?

    public init(id: String, kind: Kind = .question, chat: TopicID = .main, messageID: MessageID? = nil, text: String,
                spoken: String? = nil, summary: String? = nil, command: String? = nil, options: [QuestionOption], askedAt: Date? = nil) {
        self.askedAt = askedAt
        self.id = id
        self.kind = kind
        self.chat = chat
        self.messageID = messageID
        self.text = text
        self.spoken = spoken
        self.summary = summary
        self.command = command
        self.options = options
    }

    enum CodingKeys: String, CodingKey { case id, kind, chat, messageID = "message_id", text, spoken, summary, command, options, askedAt = "asked_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageID = c.decodeInt64(.messageID)
        id = (try? c.decode(String.self, forKey: .id)) ?? c.decodeInt64(.id).map(String.init) ?? messageID.map(String.init) ?? UUID().uuidString
        let rawKind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        chat = c.decodeTopic(.chat) ?? .main
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        spoken = try? c.decodeIfPresent(String.self, forKey: .spoken)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        command = try? c.decodeIfPresent(String.self, forKey: .command)
        options = (try? c.decode([QuestionOption].self, forKey: .options)) ?? []
        kind = Kind(rawValue: rawKind) ?? (command != nil ? .approval : .question)
        askedAt = c.decodeFlexibleDate(.askedAt)
    }
}

public struct PetState: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    public var version: Int
    public var spriteURL: URL?
    public var spriteFileID: String?
    public var spriteMessageID: MessageID?
    public var manifest: PetManifest?
    public var mood: String?
    /// The sprite row the backend wants played (Hermes' own status mapping).
    public var animation: PetAnimation?
    public var hunger: Double
    public var energy: Double
    public var happiness: Double
    public var xp: Int
    public var level: Int
    public var xpForNextLevel: Int?
    public var asleep: Bool
    public var updatedAt: Date?

    public init(id: String, name: String, version: Int = 1, spriteURL: URL? = nil, spriteFileID: String? = nil,
                spriteMessageID: MessageID? = nil, manifest: PetManifest? = nil, mood: String? = nil,
                hunger: Double = 0.3, energy: Double = 0.8, happiness: Double = 0.7, xp: Int = 0, level: Int = 1,
                xpForNextLevel: Int? = nil, asleep: Bool = false, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.spriteURL = spriteURL
        self.spriteFileID = spriteFileID
        self.spriteMessageID = spriteMessageID
        self.manifest = manifest
        self.mood = mood
        self.animation = nil
        self.hunger = hunger
        self.energy = energy
        self.happiness = happiness
        self.xp = xp
        self.level = level
        self.xpForNextLevel = xpForNextLevel
        self.asleep = asleep
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, spriteURL = "sprite_url", spriteFileID = "file_id", spriteMessageID = "sprite_message_id",
             manifest, mood, animation, hunger, energy, happiness, xp, level, xpForNextLevel = "xp_next", asleep, updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? "pet"
        name = (try? c.decode(String.self, forKey: .name)) ?? "Pet"
        version = c.decodeInt64(.version).map(Int.init) ?? 1
        spriteURL = (try? c.decodeIfPresent(String.self, forKey: .spriteURL)).flatMap { URL(string: $0) }
        spriteFileID = (try? c.decodeIfPresent(String.self, forKey: .spriteFileID)) ?? c.decodeInt64(.spriteFileID).map(String.init)
        spriteMessageID = c.decodeInt64(.spriteMessageID)
        manifest = try? c.decodeIfPresent(PetManifest.self, forKey: .manifest)
        mood = try? c.decodeIfPresent(String.self, forKey: .mood)
        animation = (try? c.decodeIfPresent(String.self, forKey: .animation)).flatMap(PetAnimation.init(alias:))
        // Gauges are 0…1; a backend sending 0…100 is scaled.
        hunger = c.decodeGauge(.hunger) ?? 0.3
        energy = c.decodeGauge(.energy) ?? 0.8
        happiness = c.decodeGauge(.happiness) ?? 0.7
        xp = c.decodeInt64(.xp).map(Int.init) ?? 0
        level = c.decodeInt64(.level).map(Int.init) ?? 1
        xpForNextLevel = c.decodeInt64(.xpForNextLevel).map(Int.init)
        asleep = (try? c.decode(Bool.self, forKey: .asleep)) ?? false
        updatedAt = c.decodeFlexibleDate(.updatedAt)
    }

    /// Total xp needed to reach `level` (protocol §5: level n needs 100·n·(n+1)/2).
    public static func totalXP(forLevel level: Int) -> Int { 100 * level * (level + 1) / 2 }

    /// Progress within the current level, 0…1.
    public var levelProgress: Double {
        let start = Double(level > 1 ? Self.totalXP(forLevel: level - 1) : 0)
        let next = Double(xpForNextLevel ?? Self.totalXP(forLevel: level))
        guard next > start else { return 0 }
        return min(max((Double(xp) - start) / (next - start), 0), 1)
    }
}

public struct SubchatInfo: Sendable, Codable, Equatable {
    public var topicID: TopicID
    public var name: String?
    public var preset: String?
    public var encrypted: Bool
    public var unlocked: Bool
    public var ttl: String?
    public var expiresAt: Date?

    public init(topicID: TopicID, name: String? = nil, preset: String? = nil, encrypted: Bool = false,
                unlocked: Bool = false, ttl: String? = nil, expiresAt: Date? = nil) {
        self.topicID = topicID
        self.name = name
        self.preset = preset
        self.encrypted = encrypted
        self.unlocked = unlocked
        self.ttl = ttl
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case topicID = "topic_id", name, preset, encrypted, unlocked, ttl, expiresAt = "expires_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let topic = c.decodeTopic(.topicID) else {
            throw DecodingError.keyNotFound(CodingKeys.topicID, .init(codingPath: c.codingPath, debugDescription: "topic_id"))
        }
        topicID = topic
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        preset = try? c.decodeIfPresent(String.self, forKey: .preset)
        encrypted = (try? c.decode(Bool.self, forKey: .encrypted)) ?? false
        unlocked = (try? c.decode(Bool.self, forKey: .unlocked)) ?? false
        ttl = try? c.decodeIfPresent(String.self, forKey: .ttl)
        expiresAt = c.decodeFlexibleDate(.expiresAt)
    }
}

public struct DeviceInfo: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var model: String?
    public var lastInstall: Date?
    public var build: String?
    public var profileExpiry: Date?

    public var os: String?
    public var reachable: Bool?
    public var lastInstallOK: Bool?
    public var lastInstallError: String?

    enum CodingKeys: String, CodingKey { case id, udid, name, model, os, reachable, lastInstall = "last_install", build, version, profileExpiry = "profile_expiry", profileExpires = "profile_expires" }
    enum InstallKeys: String, CodingKey { case at, ok, error, build, version }

    public init(id: String, name: String, model: String? = nil, lastInstall: Date? = nil, build: String? = nil, profileExpiry: Date? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.lastInstall = lastInstall
        self.build = build
        self.profileExpiry = profileExpiry
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Device"
        id = (try? c.decode(String.self, forKey: .id)) ?? (try? c.decode(String.self, forKey: .udid)) ?? name
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        os = try? c.decodeIfPresent(String.self, forKey: .os)
        reachable = try? c.decodeIfPresent(Bool.self, forKey: .reachable)
        if let install = try? c.nestedContainer(keyedBy: InstallKeys.self, forKey: .lastInstall) {
            lastInstall = install.decodeFlexibleDate(.at)
            lastInstallOK = try? install.decodeIfPresent(Bool.self, forKey: .ok)
            lastInstallError = try? install.decodeIfPresent(String.self, forKey: .error)
            let v = try? install.decodeIfPresent(String.self, forKey: .version)
            let b = (try? install.decodeIfPresent(String.self, forKey: .build)) ?? install.decodeInt64(.build).map(String.init)
            build = [v, b.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        } else {
            lastInstall = c.decodeFlexibleDate(.lastInstall)
            build = (try? c.decodeIfPresent(String.self, forKey: .build)) ?? (try? c.decodeIfPresent(String.self, forKey: .version))
        }
        profileExpiry = c.decodeFlexibleDate(.profileExpires) ?? c.decodeFlexibleDate(.profileExpiry)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(build, forKey: .build)
    }
}

// MARK: - Notify / reply

public struct NotifyPayload: Sendable, Codable, Equatable {
    public enum Interruption: String, Sendable, Codable {
        case passive, active
        case timeSensitive = "time-sensitive"
    }

    public var chat: TopicID
    public var messageID: MessageID?
    public var title: String?
    public var body: String
    public var spoken: String?
    public var interruption: Interruption
    public var kind: String?

    public init(chat: TopicID = .main, messageID: MessageID? = nil, title: String? = nil, body: String,
                spoken: String? = nil, interruption: Interruption = .active, kind: String? = nil) {
        self.chat = chat
        self.messageID = messageID
        self.title = title
        self.body = body
        self.spoken = spoken
        self.interruption = interruption
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case chat, messageID = "message_id", title, body, spoken, interruption, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chat = c.decodeTopic(.chat) ?? .main
        messageID = c.decodeInt64(.messageID)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        spoken = try? c.decodeIfPresent(String.self, forKey: .spoken)
        interruption = (try? c.decode(Interruption.self, forKey: .interruption)) ?? .active
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
    }

    /// What Siri reads: the speech variant when the backend gives one.
    public var speechText: String { spoken?.isEmpty == false ? spoken! : body }
}

public struct ReplyPayload: Sendable, Equatable {
    public var re: MessageID?
    public var ok: Bool
    public var errorCode: String?
    public var errorMessage: String?
    public var fields: [String: JSONValue]

    init(fields: [String: JSONValue]) {
        self.fields = fields
        if case .bool(let b)? = fields["ok"] { ok = b } else { ok = fields["error"] == nil }
        if case .object(let e)? = fields["error"] {
            errorCode = e["code"]?.stringValue
            errorMessage = e["message"]?.stringValue
        }
        if case .number(let n)? = fields["re"] { re = MessageID(n) }
        else if case .string(let s)? = fields["re"] { re = MessageID(s) }
        else { re = nil }
    }

    public subscript(key: String) -> JSONValue? { fields[key] }
}

// MARK: - Call mode

/// A call turn is a plain text message starting with this marker (protocol §6): Hermes answers
/// it in its spoken style.
public enum CallTurn {
    public static let marker = "🎙 "

    public static func message(for transcript: String) -> String {
        marker + transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isCallTurn(_ text: String) -> Bool { text.hasPrefix(marker) }
}
