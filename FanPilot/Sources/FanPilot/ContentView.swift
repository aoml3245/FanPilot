import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var selectedFanID: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                leftPane
                Divider()
                rightPane
            }
        }
        .frame(minWidth: 780, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("FanPilot")
                    .font(.title2.weight(.semibold))
                Text(state.statusText)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Launch at login", isOn: Binding(
                get: { state.configuration.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .help("Start FanPilot automatically when you log in.")
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(18)
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle("Fans")
            ForEach(state.fans) { fan in
                FanRow(
                    fan: fan,
                    decision: state.decisions.first { $0.fanID == fan.id },
                    isSelected: selectedFan?.id == fan.id
                )
                .onTapGesture {
                    selectedFanID = fan.id
                }
            }

            SectionTitle("Sensors")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(state.sensors) { sensor in
                        HStack {
                            Text(sensor.name)
                            Spacer()
                            Text(formatTemperature(sensor.temperatureC))
                                .monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Text(state.lastApplyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(width: 340)
    }

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(ruleSectionTitle)
                Spacer()
                Text("Live")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if let selectedFan {
                    Button("Add Rule") {
                        state.addRule(for: selectedFan)
                    }
                }
            }

            if let selectedFan {
                List {
                    ForEach(ruleBindings(for: selectedFan)) { $rule in
                        RuleEditor(
                            rule: $rule,
                            fan: selectedFan,
                            sensors: state.sensors,
                            onChange: { state.save() },
                            onDelete: { state.deleteRule(id: rule.id) }
                        )
                    }
                    .onDelete { offsets in
                        state.deleteRules(at: offsets, forFanID: selectedFan.id)
                    }
                }
                .listStyle(.inset)
            } else {
                Text("No fan selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            safetyControls
        }
        .padding(18)
        .onChange(of: state.fans) { _ in
            ensureSelectedFan()
        }
        .onAppear {
            ensureSelectedFan()
        }
    }

    private var selectedFan: Fan? {
        if let selectedFanID, let fan = state.fans.first(where: { $0.id == selectedFanID }) {
            return fan
        }
        return state.fans.first
    }

    private var ruleSectionTitle: String {
        guard let selectedFan else { return "Rules" }
        return "\(selectedFan.name) Rules"
    }

    private func ensureSelectedFan() {
        guard !state.fans.isEmpty else {
            selectedFanID = nil
            return
        }
        if selectedFanID == nil || !state.fans.contains(where: { $0.id == selectedFanID }) {
            selectedFanID = state.fans[0].id
        }
    }

    private func ruleBindings(for fan: Fan) -> [Binding<FanRule>] {
        $state.configuration.rules.filter { $rule in
            rule.fanID == fan.id
        }
    }

    private var safetyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Safety")
            HStack {
                Text("Panic")
                Slider(
                    value: Binding(
                        get: { state.configuration.safety.panicTemperatureC },
                        set: { state.configuration.safety.panicTemperatureC = $0; state.save() }
                    ),
                    in: 75...105,
                    step: 1
                )
                Text("\(Int(state.configuration.safety.panicTemperatureC)) C")
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("Step")
                Slider(
                    value: Binding(
                        get: { Double(state.configuration.safety.maximumStepRPM) },
                        set: { state.configuration.safety.maximumStepRPM = Int($0); state.save() }
                    ),
                    in: 100...1500,
                    step: 50
                )
                Text("\(state.configuration.safety.maximumStepRPM) RPM")
                    .frame(width: 72, alignment: .trailing)
            }
        }
        .font(.callout)
    }

    private func formatTemperature(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f C", value)
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
    }
}

private struct FanRow: View {
    let fan: Fan
    let decision: FanDecision?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(fan.name)
                    .font(.headline)
                Spacer()
            }
            HStack {
                Metric("Actual", "\(fan.actualRPM) RPM")
                Metric("Target", "\(decision?.requestedRPM ?? fan.targetRPM ?? fan.minimumRPM) RPM")
                Metric("Range", "\(fan.minimumRPM)-\(fan.maximumRPM)")
            }
            if let decision {
                Text(decision.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct Metric: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RuleEditor: View {
    @Binding var rule: FanRule
    let fan: Fan
    let sensors: [Sensor]
    let onChange: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("", isOn: binding(\.enabled))
                    .labelsHidden()
                TextField("Label", text: binding(\.label))
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: binding(\.mode)) {
                    ForEach(RuleMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .frame(width: 110)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this rule")
            }

            HStack {
                if rule.mode == .ramp {
                    Picker("Sensor", selection: binding(\.sensorKey)) {
                        ForEach(sensors) { sensor in
                            Text(sensor.name).tag(sensor.key)
                        }
                    }
                }
            }

            switch rule.mode {
            case .ramp:
                HStack {
                    ValueSlider(label: "Start", value: binding(\.startC), range: 35...90, suffix: "C")
                    ValueSlider(label: "Full", value: binding(\.fullC), range: 45...105, suffix: "C")
                }
            case .fixed:
                RPMSlider(
                    label: "RPM",
                    value: binding(\.fixedRPM),
                    range: fixedRPMRange
                )
            }
        }
        .padding(.vertical, 8)
    }

    private var fixedRPMRange: ClosedRange<Int> {
        return fan.minimumRPM...fan.maximumRPM
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<FanRule, Value>) -> Binding<Value> {
        Binding(
            get: { rule[keyPath: keyPath] },
            set: {
                rule[keyPath: keyPath] = $0
                onChange()
            }
        )
    }
}

private struct RPMSlider: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(label)
            Slider(value: doubleValue, in: Double(range.lowerBound)...Double(range.upperBound), step: 50)
            Text("\(clampedValue) RPM")
                .monospacedDigit()
                .frame(width: 82, alignment: .trailing)
        }
    }

    private var clampedValue: Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private var doubleValue: Binding<Double> {
        Binding(
            get: { Double(clampedValue) },
            set: { value = Int($0.rounded()) }
        )
    }
}

private struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String

    var body: some View {
        HStack {
            Text(label)
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value)) \(suffix)")
                .frame(width: 48, alignment: .trailing)
        }
    }
}
