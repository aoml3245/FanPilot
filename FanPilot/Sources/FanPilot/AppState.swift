import Foundation
import Combine
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published var fans: [Fan] = []
    @Published var sensors: [Sensor] = []
    @Published var configuration: AppConfiguration
    @Published var decisions: [FanDecision] = []
    @Published var statusText = "Starting"
    @Published var lastError: String?
    @Published var lastApplyText = "No fan write yet"
    @Published var menuBarText = "FanPilot"
    @Published var configuredSensorMenuLines: [String] = []

    private let configStore = ConfigStore()
    private var hardware: HardwareController?
    private var timer: Timer?
    private var heartbeatTimer: Timer?
    private var throttledApplyTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pollRequestedWhileRunning = false
    private var isShuttingDown = false

    init() {
        self.configuration = configStore.load()

        do {
            self.hardware = try HardwareController()
            self.statusText = "SMC connected"
            AppLog.info("SMC connected")
        } catch {
            self.statusText = "SMC unavailable"
            self.lastError = "\(error)"
            AppLog.error("SMC unavailable: \(error)")
        }

        seedDefaultRulesIfNeeded()
        updateConfiguredSensorMenuLines()
        updateMenuBarText()
    }

    func start() {
        AppLog.info("FanPilot started; log=\(AppLog.fileURL.path)")
        pollAsync()
        timer = Timer.scheduledTimer(withTimeInterval: configuration.safety.pollingIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAsync() }
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendHeartbeatIfNeeded() }
        }
    }

    func save(applyNow: Bool = true) {
        configStore.save(configuration)
        updateConfiguredSensorMenuLines()
        if applyNow {
            scheduleThrottledApply()
        }
    }

    func pollAsync() {
        guard let hardware else { return }
        guard pollTask == nil else {
            pollRequestedWhileRunning = true
            return
        }

        let configuration = configuration
        pollTask = Task { [weak self] in
            let result = await hardware.poll(configuration: configuration)
            await MainActor.run {
                guard let self else { return }
                self.pollTask = nil
                let shouldPollAgain = self.pollRequestedWhileRunning
                self.pollRequestedWhileRunning = false
                self.fans = result.fans
                self.sensors = result.sensors
                self.decisions = result.decisions
                self.statusText = result.statusText
                if let lastApplyText = result.lastApplyText {
                    self.lastApplyText = lastApplyText
                }
                self.lastError = result.lastError
                if let lastError = result.lastError {
                    AppLog.error(lastError)
                }
                self.updateConfiguredSensorMenuLines()
                self.updateMenuBarText()
                if shouldPollAgain {
                    self.pollAsync()
                }
            }
        }
    }

    func addRule(for fan: Fan) {
        let sensor = defaultRuleSensor()
        let rule = FanRule(
            fanID: fan.id,
            sensorKey: sensor?.key ?? "TC0P",
            enabled: true,
            mode: .ramp,
            startC: 50,
            fullC: 75,
            fixedRPM: fan.maximumRPM,
            label: "Rule \(configuration.rules.count + 1)"
        )
        configuration.rules.append(rule)
        AppLog.info("Added rule \(rule.id) for fan \(fan.id) \(fan.name)")
        save()
    }

    func deleteRules(at offsets: IndexSet) {
        AppLog.info("Deleting rules at offsets \(Array(offsets))")
        configuration.rules.remove(atOffsets: offsets)
        save()
    }

    func deleteRules(at offsets: IndexSet, forFanID fanID: Int) {
        let matchingIDs = configuration.rules
            .filter { $0.fanID == fanID }
            .map(\.id)
        let idsToDelete = Set(offsets.compactMap { matchingIDs.indices.contains($0) ? matchingIDs[$0] : nil })
        AppLog.info("Deleting \(idsToDelete.count) rule(s) for fan \(fanID)")
        configuration.rules.removeAll { idsToDelete.contains($0.id) }
        save()
    }

    func deleteRule(id: FanRule.ID) {
        AppLog.info("Deleting rule \(id)")
        configuration.rules.removeAll { $0.id == id }
        save()
    }

    func shutdown(completion: (() -> Void)? = nil) {
        guard !isShuttingDown else {
            completion?()
            return
        }
        isShuttingDown = true
        AppLog.info("Shutdown requested")
        throttledApplyTimer?.invalidate()
        throttledApplyTimer = nil
        pollTask?.cancel()
        pollTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pollRequestedWhileRunning = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        timer?.invalidate()
        timer = nil
        resetFanControl(reason: "app shutdown", completion: completion)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            configuration.launchAtLogin = enabled
            save(applyNow: false)
        } catch {
            configuration.launchAtLogin = false
            save(applyNow: false)
            lastError = "Launch at login update failed: \(error)"
            AppLog.error("Launch at login update failed: \(error)")
        }
    }

    private func scheduleThrottledApply() {
        guard throttledApplyTimer == nil else { return }
        throttledApplyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.throttledApplyTimer = nil
                self?.pollAsync()
            }
        }
    }

    private func sendHeartbeatIfNeeded() {
        guard let hardware else { return }
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            let error = await hardware.heartbeat()
            await MainActor.run {
                self?.heartbeatTask = nil
                guard let error else { return }
                self?.lastError = error
                AppLog.error(error)
            }
        }
    }

    private func resetFanControl(reason: String, completion: (() -> Void)? = nil) {
        guard let hardware else {
            completion?()
            return
        }
        Task { [weak self] in
            let result = await hardware.resetFanControl(reason: reason)
            await MainActor.run {
                guard let self else { return }
                if let lastApplyText = result.lastApplyText {
                    self.lastApplyText = lastApplyText
                    AppLog.info(lastApplyText)
                }
                if let lastError = result.lastError {
                    self.lastError = lastError
                    AppLog.error(lastError)
                }
                completion?()
            }
        }
    }

    private func seedDefaultRulesIfNeeded() {
        guard configuration.rules.isEmpty else { return }
        configStore.save(configuration)
    }

    private func defaultRuleSensor() -> Sensor? {
        sensors.first { $0.key == "computed.cpu.max" } ??
        sensors.first { $0.key == "computed.cpu.average" } ??
        sensors.first { $0.key == "computed.gpu.max" } ??
        sensors.first { $0.name.localizedCaseInsensitiveContains("CPU") } ??
        sensors.first
    }

    private func updateMenuBarText() {
        guard !fans.isEmpty else {
            menuBarText = "FanPilot"
            return
        }

        let selectedFan = highlightedFan()
        let actual = selectedFan.actualRPM
        let temperatureLabel = menuTemperatureLabel()

        menuBarText = "\(temperatureLabel)\n\(actual)rpm"
    }

    private func highlightedFan() -> Fan {
        return fans.max(by: { $0.actualRPM < $1.actualRPM }) ?? fans[0]
    }

    private func menuTemperatureLabel() -> String {
        guard let temperature = highestConfiguredRuleTemperature() else { return "--°" }
        return "\(Int(temperature.rounded()))°"
    }

    private func highestConfiguredRuleTemperature() -> Double? {
        let sensorByKey = Dictionary(uniqueKeysWithValues: sensors.map { ($0.key, $0) })
        return configuration.rules
            .filter { $0.enabled && $0.mode == .ramp }
            .compactMap { sensorByKey[$0.sensorKey]?.temperatureC }
            .max()
    }

    private func updateConfiguredSensorMenuLines() {
        let sensorByKey = Dictionary(uniqueKeysWithValues: sensors.map { ($0.key, $0) })
        var seen: Set<String> = []
        var lines: [String] = []

        for rule in configuration.rules where rule.mode == .ramp {
            guard !seen.contains(rule.sensorKey) else { continue }
            seen.insert(rule.sensorKey)

            let sensor = sensorByKey[rule.sensorKey]
            let name = sensor?.name ?? rule.sensorKey
            let temperature = sensor?.temperatureC.map { String(format: "%.1f C", $0) } ?? "--"
            lines.append("\(name)  \(temperature)")
        }

        configuredSensorMenuLines = lines
    }

    private func formatRPM(_ value: Int) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000.0)
        }
        return "\(value)"
    }
}
