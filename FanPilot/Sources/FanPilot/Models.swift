import Foundation

struct Fan: Identifiable, Codable, Hashable {
    let id: Int
    var name: String
    var actualRPM: Int
    var minimumRPM: Int
    var maximumRPM: Int
    var targetRPM: Int?
}

struct Sensor: Identifiable, Codable, Hashable {
    var id: String { key }
    let key: String
    var name: String
    var temperatureC: Double?
}

enum RuleMode: String, Codable, CaseIterable {
    case ramp
    case fixed
}

struct FanRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var fanID: Int
    var sensorKey: String
    var enabled: Bool
    var mode: RuleMode
    var startC: Double
    var fullC: Double
    var fixedRPM: Int
    var label: String
}

struct SafetySettings: Codable, Hashable {
    var minimumTemperatureC: Double = 35
    var panicTemperatureC: Double = 92
    var maximumStepRPM: Int = 700
    var pollingIntervalSeconds: Double = 2
}

struct AppConfiguration: Codable, Hashable {
    var safety = SafetySettings()
    var rules: [FanRule] = []
    var launchAtLogin = false

    enum CodingKeys: String, CodingKey {
        case safety
        case rules
        case launchAtLogin
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        safety = try container.decodeIfPresent(SafetySettings.self, forKey: .safety) ?? SafetySettings()
        rules = try container.decodeIfPresent([FanRule].self, forKey: .rules) ?? []
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }
}

struct FanDecision: Hashable {
    let fanID: Int
    let requestedRPM: Int
    let reason: String
    var sensorName: String?
    var sensorTemperatureC: Double?
}

extension Fan {
    func clampedRPM(_ rpm: Int) -> Int {
        min(max(rpm, minimumRPM), maximumRPM)
    }
}
