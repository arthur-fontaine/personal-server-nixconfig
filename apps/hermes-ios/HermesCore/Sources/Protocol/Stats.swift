import Foundation

/// `state.stats`: the machine and the models' usage, as the backend measures them.
public struct StatsState: Sendable, Codable, Equatable {
    public var machine: MachineStats?
    public var models: [ModelUsage]
    public var updatedAt: Date?

    public init(machine: MachineStats? = nil, models: [ModelUsage] = [], updatedAt: Date? = nil) {
        self.machine = machine
        self.models = models
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case machine, models, updatedAt = "updated_at" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try? c.decodeIfPresent(MachineStats.self, forKey: .machine)
        models = ((try? c.decode([LossyModel].self, forKey: .models)) ?? []).compactMap(\.value)
        updatedAt = c.decodeFlexibleDate(.updatedAt)
    }

    private struct LossyModel: Decodable {
        let value: ModelUsage?
        init(from decoder: Decoder) throws { value = try? ModelUsage(from: decoder) }
    }
}

public struct MachineStats: Sendable, Codable, Equatable {
    public var cpuPercent: Double?
    public var ramUsed: Int64?
    public var ramTotal: Int64?
    public var diskUsed: Int64?
    public var diskTotal: Int64?
    public var powerWatts: Double?
    public var energyKWh24h: Double?
    public var batteryPercent: Double?
    public var charging: Bool?
    public var uptime: TimeInterval?
    public var temperatureC: Double?
    public var cpuHistory: [Double]
    public var ramHistory: [Double]
    public var powerHistory: [Double]

    public init(cpuPercent: Double? = nil, ramUsed: Int64? = nil, ramTotal: Int64? = nil, diskUsed: Int64? = nil,
                diskTotal: Int64? = nil, powerWatts: Double? = nil, energyKWh24h: Double? = nil,
                batteryPercent: Double? = nil, charging: Bool? = nil, uptime: TimeInterval? = nil,
                temperatureC: Double? = nil, cpuHistory: [Double] = [], ramHistory: [Double] = [], powerHistory: [Double] = []) {
        self.cpuPercent = cpuPercent
        self.ramUsed = ramUsed
        self.ramTotal = ramTotal
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.powerWatts = powerWatts
        self.energyKWh24h = energyKWh24h
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.uptime = uptime
        self.temperatureC = temperatureC
        self.cpuHistory = cpuHistory
        self.ramHistory = ramHistory
        self.powerHistory = powerHistory
    }

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "cpu_pct", ramUsed = "ram_used", ramTotal = "ram_total", diskUsed = "disk_used", diskTotal = "disk_total",
             powerWatts = "power_w", energyKWh24h = "energy_kwh_24h", batteryPercent = "battery_pct", charging,
             uptime = "uptime_s", temperatureC = "temp_c", history
    }

    enum HistoryKeys: String, CodingKey { case cpu, ram, power }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpuPercent = c.decodeDouble(.cpuPercent)
        ramUsed = c.decodeInt64(.ramUsed)
        ramTotal = c.decodeInt64(.ramTotal)
        diskUsed = c.decodeInt64(.diskUsed)
        diskTotal = c.decodeInt64(.diskTotal)
        powerWatts = c.decodeDouble(.powerWatts)
        energyKWh24h = c.decodeDouble(.energyKWh24h)
        batteryPercent = c.decodeDouble(.batteryPercent)
        charging = try? c.decodeIfPresent(Bool.self, forKey: .charging)
        uptime = c.decodeDouble(.uptime)
        temperatureC = c.decodeDouble(.temperatureC)
        let h = try? c.nestedContainer(keyedBy: HistoryKeys.self, forKey: .history)
        cpuHistory = (try? h?.decode([Double].self, forKey: .cpu)) ?? []
        ramHistory = (try? h?.decode([Double].self, forKey: .ram)) ?? []
        powerHistory = (try? h?.decode([Double].self, forKey: .power)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(cpuPercent, forKey: .cpuPercent)
        try c.encodeIfPresent(ramUsed, forKey: .ramUsed)
        try c.encodeIfPresent(ramTotal, forKey: .ramTotal)
        try c.encodeIfPresent(diskUsed, forKey: .diskUsed)
        try c.encodeIfPresent(diskTotal, forKey: .diskTotal)
        try c.encodeIfPresent(powerWatts, forKey: .powerWatts)
        try c.encodeIfPresent(batteryPercent, forKey: .batteryPercent)
    }

    public var ramFraction: Double? { fraction(ramUsed, ramTotal) }
    public var diskFraction: Double? { fraction(diskUsed, diskTotal) }

    private func fraction(_ used: Int64?, _ total: Int64?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return Double(used) / Double(total)
    }
}

public enum UsageWindow: String, Sendable, Codable, CaseIterable, Identifiable {
    case day = "24h", week = "7d", month = "30d"
    public var id: String { rawValue }
}

public struct UsageFigures: Sendable, Codable, Equatable {
    public var calls: Int
    public var tokensIn: Int
    public var tokensOut: Int
    public var tokensCached: Int
    public var costUSD: Double
    public var errors: Int

    public init(calls: Int = 0, tokensIn: Int = 0, tokensOut: Int = 0, tokensCached: Int = 0, costUSD: Double = 0, errors: Int = 0) {
        self.calls = calls
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.tokensCached = tokensCached
        self.costUSD = costUSD
        self.errors = errors
    }

    enum CodingKeys: String, CodingKey {
        case calls, tokensIn = "tokens_in", tokensOut = "tokens_out", tokensCached = "tokens_cached", costUSD = "cost_usd", cost, errors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = c.decodeInt64(.calls).map(Int.init) ?? 0
        tokensIn = c.decodeInt64(.tokensIn).map(Int.init) ?? 0
        tokensOut = c.decodeInt64(.tokensOut).map(Int.init) ?? 0
        tokensCached = c.decodeInt64(.tokensCached).map(Int.init) ?? 0
        costUSD = c.decodeDouble(.costUSD) ?? c.decodeDouble(.cost) ?? 0
        errors = c.decodeInt64(.errors).map(Int.init) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(calls, forKey: .calls)
        try c.encode(tokensIn, forKey: .tokensIn)
        try c.encode(tokensOut, forKey: .tokensOut)
        try c.encode(tokensCached, forKey: .tokensCached)
        try c.encode(costUSD, forKey: .costUSD)
        try c.encode(errors, forKey: .errors)
    }

    public var totalTokens: Int { tokensIn + tokensOut }
    /// Share of input tokens served from the provider's cache.
    public var cacheRatio: Double { tokensIn > 0 ? Double(tokensCached) / Double(tokensIn) : 0 }
}

public struct ModelUsage: Sendable, Codable, Equatable, Identifiable {
    public enum Role: String, Sendable, Codable {
        case main, fallback, background, local, decision, other
    }

    public var id: String { "\(provider):\(model)" }
    public var provider: String
    public var model: String
    public var role: Role
    /// Position in the fallback chain, 0 = main.
    public var rank: Int
    public var windows: [UsageWindow: UsageFigures]
    public var lastUsed: Date?

    public init(provider: String, model: String, role: Role, rank: Int = 0, windows: [UsageWindow: UsageFigures], lastUsed: Date? = nil) {
        self.provider = provider
        self.model = model
        self.role = role
        self.rank = rank
        self.windows = windows
        self.lastUsed = lastUsed
    }

    enum CodingKeys: String, CodingKey { case provider, model, role, rank, windows, window, lastUsed = "last_used" }

    /// Accepts both `windows: {"24h": {...}}` and flat figures with a `window` key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(String.self, forKey: .provider)) ?? "?"
        model = try c.decode(String.self, forKey: .model)
        role = (try? c.decode(String.self, forKey: .role)).flatMap(Role.init(rawValue:)) ?? .other
        rank = c.decodeInt64(.rank).map(Int.init) ?? (role == .main ? 0 : 1)
        lastUsed = c.decodeFlexibleDate(.lastUsed)
        if let nested = try? c.decode([String: UsageFigures].self, forKey: .windows) {
            windows = Dictionary(uniqueKeysWithValues: nested.compactMap { k, v in UsageWindow(rawValue: k).map { ($0, v) } })
        } else {
            let window = (try? c.decode(String.self, forKey: .window)).flatMap(UsageWindow.init(rawValue:)) ?? .day
            windows = [window: try UsageFigures(from: decoder)]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(model, forKey: .model)
        try c.encode(role.rawValue, forKey: .role)
        try c.encode(Dictionary(uniqueKeysWithValues: windows.map { ($0.key.rawValue, $0.value) }), forKey: .windows)
    }

    public func figures(_ window: UsageWindow) -> UsageFigures { windows[window] ?? UsageFigures() }
}
