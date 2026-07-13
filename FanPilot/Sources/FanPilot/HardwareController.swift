import Foundation
import IOKit

struct HardwarePollResult: Sendable {
    var fans: [Fan]
    var sensors: [Sensor]
    var decisions: [FanDecision]
    var statusText: String
    var lastApplyText: String?
    var lastError: String?
}

actor HardwareController {
    private let smc: SMC
    private let engine = RuleEngine()
    private var helperWritesRequired = false
    private var lastValidSensorTemperatures: [String: Double] = [:]

    init() throws {
        self.smc = try SMC()
        AppLog.info("HardwareController initialized")
    }

    func poll(configuration: AppConfiguration) -> HardwarePollResult {
        do {
            let fans = try smc.readFans()
            let sensors = stabilizeSensors(try smc.readSensors())
            let decisions = engine.decide(
                fans: fans,
                sensors: sensors,
                rules: configuration.rules,
                safety: configuration.safety
            )
            let applyResult = apply(decisions, fans: fans, safety: configuration.safety)
            return HardwarePollResult(
                fans: fans,
                sensors: sensors,
                decisions: decisions,
                statusText: "Applying fan targets",
                lastApplyText: applyResult.lastApplyText,
                lastError: applyResult.lastError
            )
        } catch {
            AppLog.error("Poll read failed: \(error)")
            return HardwarePollResult(
                fans: [],
                sensors: [],
                decisions: [],
                statusText: "Read failed",
                lastApplyText: nil,
                lastError: "\(error)"
            )
        }
    }

    func heartbeat() -> String? {
        do {
            try HelperClient.heartbeat()
            return nil
        } catch {
            AppLog.error("Helper heartbeat failed: \(error)")
            return "Helper heartbeat failed: \(error)"
        }
    }

    func resetFanControl(reason: String) -> (lastApplyText: String?, lastError: String?) {
        do {
            try smc.resetFanControl()
            AppLog.info("Fan control reset (\(reason))")
            return ("Fan control reset (\(reason))", nil)
        } catch {
            AppLog.warning("Direct fan reset failed; trying helper: \(error)")
            do {
                try HelperClient.resetFanControl()
                AppLog.info("Fan control reset via helper (\(reason))")
                return ("Fan control reset via helper (\(reason))", nil)
            } catch {
                AppLog.error("Reset fan control failed: \(error)")
                return (nil, "Reset fan control failed: \(error)")
            }
        }
    }

    private func stabilizeSensors(_ sensors: [Sensor]) -> [Sensor] {
        sensors.map { sensor in
            if let temperature = sensor.temperatureC {
                lastValidSensorTemperatures[sensor.key] = temperature
                return sensor
            }

            guard let cached = lastValidSensorTemperatures[sensor.key] else {
                return sensor
            }

            return Sensor(key: sensor.key, name: sensor.name, temperatureC: cached)
        }
    }

    private func apply(_ decisions: [FanDecision], fans: [Fan], safety: SafetySettings) -> (lastApplyText: String?, lastError: String?) {
        var lastApplyText: String?
        var lastError: String?

        for decision in decisions {
            guard let fan = fans.first(where: { $0.id == decision.fanID }) else { continue }
            let currentTarget = fan.targetRPM ?? fan.actualRPM
            let delta = decision.requestedRPM - currentTarget
            let limitedRPM: Int

            if abs(delta) > safety.maximumStepRPM {
                limitedRPM = currentTarget + (delta > 0 ? safety.maximumStepRPM : -safety.maximumStepRPM)
            } else {
                limitedRPM = decision.requestedRPM
            }

            do {
                let rpm = fan.clampedRPM(limitedRPM)
                if helperWritesRequired {
                    try HelperClient.setFanTarget(fanID: decision.fanID, rpm: rpm)
                } else {
                    do {
                        try smc.setFanTarget(fanID: decision.fanID, rpm: rpm)
                    } catch SMCError.callFailed(let code) where code == kIOReturnNotPrivileged {
                        helperWritesRequired = true
                        AppLog.warning("Direct SMC write not privileged; using helper for subsequent writes")
                        try HelperClient.setFanTarget(fanID: decision.fanID, rpm: rpm)
                    }
                }
                lastApplyText = "\(fan.name): wrote \(rpm) RPM (\(decision.reason))"
            } catch {
                lastError = "Write failed for fan \(decision.fanID): \(error)"
                AppLog.error(lastError ?? "Write failed for fan \(decision.fanID): \(error)")
            }
        }

        return (lastApplyText, lastError)
    }
}
