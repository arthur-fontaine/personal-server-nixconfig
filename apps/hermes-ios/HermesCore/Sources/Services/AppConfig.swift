import Foundation

/// Build-time settings, read from Info.plist keys the xcconfig fills (project.yml).
public struct AppConfig: Sendable, Equatable {
    public var botUsername: String
    public var apiID: Int32?
    public var apiHash: String?
    public var appGroup: String?
    public var paidTeam: Bool
    public var swissTransferToken: String?
    public var deviceName: String
    public var demo: Bool

    public init(botUsername: String, apiID: Int32? = nil, apiHash: String? = nil, appGroup: String? = nil,
                paidTeam: Bool = false, swissTransferToken: String? = nil, deviceName: String = "iPhone", demo: Bool = false) {
        self.botUsername = botUsername
        self.apiID = apiID
        self.apiHash = apiHash
        self.appGroup = appGroup
        self.paidTeam = paidTeam
        self.swissTransferToken = swissTransferToken
        self.deviceName = deviceName
        self.demo = demo
    }

    public static func fromBundle(_ bundle: Bundle = .main, arguments: [String] = ProcessInfo.processInfo.arguments,
                                  deviceName: String = "iPhone") -> AppConfig {
        func value(_ key: String) -> String? {
            guard let s = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespaces)
            // An unset build setting stays as "$(NAME)" in some toolchains.
            return t.isEmpty || t.hasPrefix("$(") ? nil : t
        }
        let apiID = value("HermesTelegramApiId").flatMap(Int32.init)
        let apiHash = value("HermesTelegramApiHash")
        let username = (value("HermesBotUsername") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        // Without Telegram credentials there is nothing to connect to: run on the fixtures.
        let demo = arguments.contains("-demo") || apiID == nil || apiHash == nil
        return AppConfig(botUsername: username.isEmpty ? "hermes_bot" : username, apiID: apiID, apiHash: apiHash,
                         appGroup: value("HermesAppGroup"), paidTeam: value("HermesPaidTeam") == "1",
                         swissTransferToken: value("HermesSwissTransferToken"), deviceName: deviceName, demo: demo)
    }

    public static let preview = AppConfig(botUsername: "hermes_bot", appGroup: nil, demo: true)
}
