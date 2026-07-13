import Foundation

final class RuleEngine {
    func decide(fans: [Fan], sensors: [Sensor], rules: [FanRule], safety: SafetySettings) -> [FanDecision] {
        let sensorByKey = Dictionary(uniqueKeysWithValues: sensors.map { ($0.key, $0) })
        var bestByFan: [Int: FanDecision] = [:]

        for fan in fans {
            bestByFan[fan.id] = FanDecision(
                fanID: fan.id,
                requestedRPM: fan.minimumRPM,
                reason: "minimum",
                sensorName: nil,
                sensorTemperatureC: nil
            )
        }

        for rule in rules where rule.enabled {
            guard let fan = fans.first(where: { $0.id == rule.fanID }) else {
                continue
            }

            let sensor = sensorByKey[rule.sensorKey]
            let temperatureC = sensor?.temperatureC
            guard rule.mode == .fixed || temperatureC != nil else { continue }

            let requested = rpm(for: rule, fan: fan, temperatureC: temperatureC)
            let clamped = fan.clampedRPM(requested)
            let reason: String
            if rule.mode == .fixed {
                reason = "\(rule.label): fixed \(clamped) RPM"
            } else if let sensor, let temperatureC {
                reason = "\(rule.label): \(sensor.name) \(String(format: "%.1f", temperatureC))C"
            } else {
                reason = rule.label
            }

            if clamped > (bestByFan[fan.id]?.requestedRPM ?? 0) {
                bestByFan[fan.id] = FanDecision(
                    fanID: fan.id,
                    requestedRPM: clamped,
                    reason: reason,
                    sensorName: rule.mode == .fixed ? nil : sensor?.name,
                    sensorTemperatureC: rule.mode == .fixed ? nil : temperatureC
                )
            }
        }

        let hottest = sensors.compactMap(\.temperatureC).max() ?? 0
        if hottest >= safety.panicTemperatureC {
            for fan in fans {
                bestByFan[fan.id] = FanDecision(
                    fanID: fan.id,
                    requestedRPM: fan.maximumRPM,
                    reason: "panic temperature guard",
                    sensorName: "Panic",
                    sensorTemperatureC: hottest
                )
            }
        }

        return fans.compactMap { bestByFan[$0.id] }
    }

    private func rpm(for rule: FanRule, fan: Fan, temperatureC: Double?) -> Int {
        switch rule.mode {
        case .fixed:
            return rule.fixedRPM
        case .ramp:
            guard let temperatureC else { return fan.minimumRPM }
            guard rule.fullC > rule.startC else { return fan.maximumRPM }
            if temperatureC <= rule.startC { return fan.minimumRPM }
            if temperatureC >= rule.fullC { return fan.maximumRPM }

            let progress = (temperatureC - rule.startC) / (rule.fullC - rule.startC)
            let span = Double(fan.maximumRPM - fan.minimumRPM)
            return fan.minimumRPM + Int((span * progress).rounded())
        }
    }
}
