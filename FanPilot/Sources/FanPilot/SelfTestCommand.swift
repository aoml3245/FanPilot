import Foundation

enum SelfTestCommand {
    static func run() {
        do {
            try testChoosesHighestRequestedRPMAcrossRulesForSameFan()
            try testFixedRuleDoesNotRequireSensorTemperature()
            try testPanicTemperatureForcesMaximumRPM()
            print("FanPilot self-test passed")
        } catch {
            fputs("FanPilot self-test failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func testChoosesHighestRequestedRPMAcrossRulesForSameFan() throws {
        let fan = Fan(id: 0, name: "Left", actualRPM: 2400, minimumRPM: 2000, maximumRPM: 6000, targetRPM: nil)
        let sensors = [
            Sensor(key: "cpu", name: "CPU", temperatureC: 70),
            Sensor(key: "gpu", name: "GPU", temperatureC: 60)
        ]
        let rules = [
            FanRule(fanID: 0, sensorKey: "cpu", enabled: true, mode: .ramp, startC: 50, fullC: 90, fixedRPM: 6000, label: "CPU ramp"),
            FanRule(fanID: 0, sensorKey: "gpu", enabled: true, mode: .fixed, startC: 55, fullC: 90, fixedRPM: 5400, label: "GPU floor")
        ]

        let decisions = RuleEngine().decide(fans: [fan], sensors: sensors, rules: rules, safety: SafetySettings())
        try expect(decisions.first?.requestedRPM == 5400, "expected highest RPM rule to win")
        try expect(decisions.first?.fanID == 0, "expected fan 0 decision")
    }

    private static func testFixedRuleDoesNotRequireSensorTemperature() throws {
        let fan = Fan(id: 0, name: "Left", actualRPM: 2400, minimumRPM: 2000, maximumRPM: 6000, targetRPM: nil)
        let rule = FanRule(fanID: 0, sensorKey: "missing", enabled: true, mode: .fixed, startC: 70, fullC: 90, fixedRPM: 4200, label: "Fixed")

        let decisions = RuleEngine().decide(fans: [fan], sensors: [], rules: [rule], safety: SafetySettings())
        try expect(decisions.first?.requestedRPM == 4200, "expected fixed rule to apply without sensor data")
        try expect(decisions.first?.sensorTemperatureC == nil, "expected fixed rule not to report sensor temperature")
    }

    private static func testPanicTemperatureForcesMaximumRPM() throws {
        let fan = Fan(id: 0, name: "Left", actualRPM: 2400, minimumRPM: 2000, maximumRPM: 6000, targetRPM: nil)
        let sensors = [Sensor(key: "cpu", name: "CPU", temperatureC: 95)]
        let rule = FanRule(fanID: 0, sensorKey: "cpu", enabled: true, mode: .ramp, startC: 50, fullC: 90, fixedRPM: 6000, label: "CPU ramp")
        var safety = SafetySettings()
        safety.panicTemperatureC = 92

        let decisions = RuleEngine().decide(fans: [fan], sensors: sensors, rules: [rule], safety: safety)
        try expect(decisions.first?.requestedRPM == 6000, "expected panic guard to force maximum RPM")
        try expect(decisions.first?.reason == "panic temperature guard", "expected panic reason")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw SelfTestError.failed(message)
        }
    }
}

enum SelfTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}
