import Foundation
import IOKit

enum SMCError: Error {
    case serviceUnavailable
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcWriteRejected(String, UInt8)
    case badData
    case unsupportedDataType(String)
}

final class SMC {
    private var connection: io_connect_t = 0
    private var fanModeKeyIsLowercase: Bool?

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceUnavailable }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw SMCError.openFailed(result) }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func readFanCount() throws -> Int {
        Int(try readNumber("FNum"))
    }

    func readFans() throws -> [Fan] {
        let count = try readFanCount()
        return try (0..<count).map { index in
            Fan(
                id: index,
                name: fanName(index),
                actualRPM: Int(try readNumber("F\(index)Ac").rounded()),
                minimumRPM: Int(try readNumber("F\(index)Mn").rounded()),
                maximumRPM: Int(try readNumber("F\(index)Mx").rounded()),
                targetRPM: try? Int(readNumber("F\(index)Tg").rounded())
            )
        }
    }

    func readSensors() throws -> [Sensor] {
        var sensors: [Sensor] = []
        for item in KnownSMCSensor.all {
            let temperature = validTemperature(for: item.key)
            sensors.append(Sensor(key: item.key, name: item.name, temperatureC: temperature))
        }
        sensors.append(contentsOf: computedSensors(from: sensors))
        return sensors.sorted { $0.name < $1.name }
    }

    func setFanTarget(fanID: Int, rpm: Int) throws {
        try setFanForced(fanID: fanID)
        try writeFanTarget("F\(fanID)Tg", value: Double(rpm))
    }

    func resetFanControl() throws {
        if var ftst = try? readPayload(key: "Ftst"), !ftst.bytes.isEmpty {
            ftst.bytes[0] = 0
            try writeWithRetry(key: "Ftst", bytes: ftst.bytes, dataType: ftst.dataType, dataSize: ftst.dataSize)
        }

        let count = (try? readFanCount()) ?? 0
        for id in 0..<count {
            let key = fanModeKey(id)
            guard var mode = try? readPayload(key: key), !mode.bytes.isEmpty else { continue }
            mode.bytes[0] = 0
            try? writeWithRetry(key: key, bytes: mode.bytes, dataType: mode.dataType, dataSize: mode.dataSize)
        }
    }

    private func fanName(_ index: Int) -> String {
        let key = "F\(index)ID"
        guard let payload = try? readPayload(key: key), !payload.bytes.isEmpty else {
            return "Fan \(index)"
        }

        let bytes: [UInt8]
        if payload.dataType == "{fds", payload.bytes.count >= 16 {
            bytes = Array(payload.bytes[4..<16])
        } else {
            bytes = payload.bytes
        }

        let text = String(bytes: bytes.filter { $0 != 0 }, encoding: .utf8)
        return text?.isEmpty == false ? text! : "Fan \(index)"
    }

    private func computedSensors(from sensors: [Sensor]) -> [Sensor] {
        var computed: [Sensor] = []
        let cpuTemperatures = sensors
            .filter { $0.key.isCPUTemperatureKey }
            .compactMap(\.temperatureC)
        let gpuTemperatures = sensors
            .filter { $0.key.isGPUTemperatureKey }
            .compactMap(\.temperatureC)

        computed.append(Sensor(key: "computed.cpu.average", name: "CPU Average", temperatureC: average(cpuTemperatures)))
        computed.append(Sensor(key: "computed.cpu.max", name: "CPU Max", temperatureC: cpuTemperatures.max()))
        computed.append(Sensor(key: "computed.gpu.average", name: "GPU Average", temperatureC: average(gpuTemperatures)))
        computed.append(Sensor(key: "computed.gpu.max", name: "GPU Max", temperatureC: gpuTemperatures.max()))

        return computed
    }

    private func validTemperature(for key: String) -> Double? {
        guard let temperature = try? readNumber(key), temperature >= 10, temperature < 120 else {
            return nil
        }
        return temperature
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func fanModeKey(_ id: Int) -> String {
        #if arch(arm64)
        if fanModeKeyIsLowercase == nil {
            fanModeKeyIsLowercase = (try? readPayload(key: "F0md")) != nil
        }
        return fanModeKeyIsLowercase == true ? "F\(id)md" : "F\(id)Md"
        #else
        return "F\(id)Md"
        #endif
    }

    private func setFanForced(fanID: Int) throws {
        #if arch(arm64)
        let key = fanModeKey(fanID)
        var mode = try readPayload(key: key)
        if mode.bytes.first == 1 { return }

        mode.bytes[0] = 1
        do {
            try writeWithRetry(key: key, bytes: mode.bytes, dataType: mode.dataType, dataSize: mode.dataSize)
            return
        } catch {
            if var ftst = try? readPayload(key: "Ftst"), !ftst.bytes.isEmpty {
                ftst.bytes[0] = 1
                try writeWithRetry(key: "Ftst", bytes: ftst.bytes, dataType: ftst.dataType, dataSize: ftst.dataSize, attempts: 100)
                usleep(3_000_000)
                mode.bytes[0] = 1
                try writeWithRetry(key: key, bytes: mode.bytes, dataType: mode.dataType, dataSize: mode.dataSize, attempts: 30)
                return
            }
            throw error
        }
        #else
        var fs = try readPayload(key: "FS! ")
        var mode = Int(try readNumber("FS! "))
        mode = mode | (fanID == 0 ? 1 : 2)
        fs.bytes = [0, UInt8(mode)] + Array(repeating: 0, count: 30)
        try writeWithRetry(key: "FS! ", bytes: fs.bytes, dataType: fs.dataType, dataSize: fs.dataSize)
        #endif
    }

    private func readNumber(_ key: String) throws -> Double {
        let payload = try readPayload(key: key)
        let bytes = payload.bytes

        switch payload.dataType {
        case "ui8 ":
            guard let first = bytes.first else { throw SMCError.badData }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { throw SMCError.badData }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { throw SMCError.badData }
            let raw = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return Double(raw)
        case "sp78":
            guard bytes.count >= 2 else { throw SMCError.badData }
            return Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 256.0
        case "sp87":
            guard bytes.count >= 2 else { throw SMCError.badData }
            return Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 128.0
        case "sp96":
            guard bytes.count >= 2 else { throw SMCError.badData }
            return Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 64.0
        case "fpe2":
            guard bytes.count >= 2 else { throw SMCError.badData }
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case "flt ":
            guard bytes.count >= 4 else { throw SMCError.badData }
            return Double(bytes.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float.self) })
        default:
            throw SMCError.unsupportedDataType(payload.dataType)
        }
    }

    private func writeFanTarget(_ key: String, value: Double) throws {
        let payload = try readPayload(key: key)

        if payload.dataType == "flt " {
            var float = Float(value)
            let bytes = withUnsafeBytes(of: &float) { Array($0) }
            try writeWithRetry(key: key, bytes: bytes, dataType: payload.dataType, dataSize: payload.dataSize)
            return
        }

        let rpm = Int(max(0, min(value, Double(UInt16.max))))
        let bytes = [UInt8(rpm >> 6), UInt8((rpm << 2) ^ ((rpm >> 6) << 8))]
        try writeWithRetry(key: key, bytes: bytes, dataType: payload.dataType, dataSize: payload.dataSize)
    }

    private func readPayload(key: String) throws -> SMCPayload {
        var infoInput = SMCKeyData()
        infoInput.key = key.smcKey
        infoInput.data8 = SMCCommand.readKeyInfo.rawValue

        let infoOutput = try call(infoInput)
        let size = Int(infoOutput.keyInfo.dataSize)
        guard size > 0, size <= 32 else { throw SMCError.badData }

        var readInput = SMCKeyData()
        readInput.key = key.smcKey
        readInput.keyInfo = infoOutput.keyInfo
        readInput.data8 = SMCCommand.readBytes.rawValue

        let readOutput = try call(readInput)
        return SMCPayload(
            bytes: Array(readOutput.bytes.array.prefix(size)),
            dataType: infoOutput.keyInfo.dataType.smcString,
            dataSize: UInt32(size)
        )
    }

    private func writeWithRetry(key: String, bytes: [UInt8], dataType: String, dataSize: UInt32, attempts: Int = 10) throws {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                try write(key: key, bytes: bytes, dataType: dataType, dataSize: dataSize)
                return
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    usleep(50_000)
                }
            }
        }
        throw lastError ?? SMCError.smcWriteRejected(key, 0xff)
    }

    private func write(key: String, bytes: [UInt8], dataType: String, dataSize: UInt32) throws {
        var input = SMCKeyData()
        input.key = key.smcKey
        input.data8 = SMCCommand.writeBytes.rawValue
        input.keyInfo.dataSize = dataSize
        input.keyInfo.dataType = dataType.smcKey

        for (index, byte) in bytes.prefix(32).enumerated() {
            input.bytes[index] = byte
        }

        let output = try call(input)
        guard output.result == 0 else {
            throw SMCError.smcWriteRejected(key, output.result)
        }
    }

    private func call(_ input: SMCKeyData) throws -> SMCKeyData {
        var input = input
        var output = SMCKeyData()
        var inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                inputPointer.withMemoryRebound(to: UInt8.self, capacity: inputSize) { inputBytes in
                    outputPointer.withMemoryRebound(to: UInt8.self, capacity: outputSize) { outputBytes in
                        IOConnectCallStructMethod(
                            connection,
                            UInt32(SMCSelector.call.rawValue),
                            inputBytes,
                            inputSize,
                            outputBytes,
                            &outputSize
                        )
                    }
                }
            }
        }

        guard result == KERN_SUCCESS else { throw SMCError.callFailed(result) }
        return output
    }
}

private struct SMCPayload {
    var bytes: [UInt8]
    let dataType: String
    let dataSize: UInt32
}

private enum SMCSelector: Int {
    case call = 2
}

private enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readKeyInfo = 9
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCBytes {
    private var b00: UInt8 = 0
    private var b01: UInt8 = 0
    private var b02: UInt8 = 0
    private var b03: UInt8 = 0
    private var b04: UInt8 = 0
    private var b05: UInt8 = 0
    private var b06: UInt8 = 0
    private var b07: UInt8 = 0
    private var b08: UInt8 = 0
    private var b09: UInt8 = 0
    private var b10: UInt8 = 0
    private var b11: UInt8 = 0
    private var b12: UInt8 = 0
    private var b13: UInt8 = 0
    private var b14: UInt8 = 0
    private var b15: UInt8 = 0
    private var b16: UInt8 = 0
    private var b17: UInt8 = 0
    private var b18: UInt8 = 0
    private var b19: UInt8 = 0
    private var b20: UInt8 = 0
    private var b21: UInt8 = 0
    private var b22: UInt8 = 0
    private var b23: UInt8 = 0
    private var b24: UInt8 = 0
    private var b25: UInt8 = 0
    private var b26: UInt8 = 0
    private var b27: UInt8 = 0
    private var b28: UInt8 = 0
    private var b29: UInt8 = 0
    private var b30: UInt8 = 0
    private var b31: UInt8 = 0

    var array: [UInt8] {
        withUnsafeBytes(of: self) { Array($0) }
    }

    subscript(index: Int) -> UInt8 {
        get { array[index] }
        set {
            withUnsafeMutableBytes(of: &self) { rawBuffer in
                rawBuffer[index] = newValue
            }
        }
    }
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var pLimitData: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCBytes()
}

private extension String {
    var smcKey: UInt32 {
        var result: UInt32 = 0
        for scalar in unicodeScalars.prefix(4) {
            result = (result << 8) + UInt32(scalar.value)
        }
        return result
    }

    var isCPUTemperatureKey: Bool {
        hasPrefix("TC") || hasPrefix("Tp") || hasPrefix("Te") || hasPrefix("Tf")
    }

    var isGPUTemperatureKey: Bool {
        hasPrefix("TG") || hasPrefix("Tg")
    }
}

private extension UInt32 {
    var smcString: String {
        let scalars: [UnicodeScalar] = [
            UnicodeScalar((self >> 24) & 0xff) ?? " ",
            UnicodeScalar((self >> 16) & 0xff) ?? " ",
            UnicodeScalar((self >> 8) & 0xff) ?? " ",
            UnicodeScalar(self & 0xff) ?? " "
        ]
        return String(String.UnicodeScalarView(scalars))
    }
}

private struct KnownSMCSensor {
    let key: String
    let name: String

    static let all: [KnownSMCSensor] = [
        .init(key: "TC0P", name: "CPU Proximity"),
        .init(key: "TC0E", name: "CPU Efficiency"),
        .init(key: "TC0F", name: "CPU Performance"),
        .init(key: "TC0H", name: "CPU Heatsink"),
        .init(key: "TC0D", name: "CPU Diode"),
        .init(key: "TG0P", name: "GPU Proximity"),
        .init(key: "TG0D", name: "GPU Diode"),
        .init(key: "TM0P", name: "Memory Proximity"),
        .init(key: "TB0T", name: "Battery"),
        .init(key: "Tp09", name: "SoC Performance 0"),
        .init(key: "Tp0T", name: "SoC Performance 1"),
        .init(key: "Tp01", name: "SoC Performance 2"),
        .init(key: "Tp05", name: "CPU Performance Core 2"),
        .init(key: "Tp0D", name: "CPU Performance Core 4"),
        .init(key: "Tp0X", name: "CPU Performance Core 5"),
        .init(key: "Tp0b", name: "CPU Performance Core 6"),
        .init(key: "Tp0f", name: "CPU Performance Core 7"),
        .init(key: "Tp0j", name: "CPU Performance Core 8"),
        .init(key: "Tp1h", name: "CPU Efficiency Core 1"),
        .init(key: "Tp1t", name: "CPU Efficiency Core 2"),
        .init(key: "Tp1p", name: "CPU Efficiency Core 3"),
        .init(key: "Tp1l", name: "CPU Efficiency Core 4"),
        .init(key: "Te05", name: "SoC Efficiency 0"),
        .init(key: "Te0S", name: "SoC Efficiency 1"),
        .init(key: "Tg0f", name: "GPU Core 1"),
        .init(key: "Tg0j", name: "GPU Core 2"),
        .init(key: "Tm02", name: "Memory 0"),
        .init(key: "Tm06", name: "Memory 1")
    ]
}
