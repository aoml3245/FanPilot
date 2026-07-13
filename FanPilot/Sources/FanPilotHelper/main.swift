import Darwin
import Foundation
import IOKit

private let socketPath = "/tmp/fanpilot-helper.sock"
private var lastHeartbeat = Date.distantPast
private var manualControlActive = false

private func helperLog(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let url = URL(fileURLWithPath: "/Library/Logs/FanPilotHelper.log")
    do {
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: [.atomic])
        }
    } catch {
        fputs("FanPilotHelper log failed: \(error)\n", stderr)
    }
}

enum HelperError: Error {
    case serviceUnavailable
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcWriteRejected(String, UInt8)
    case badData
    case badCommand
}

final class FanPilotHelperSMC {
    private var connection: io_connect_t = 0
    private var fanModeKeyIsLowercase: Bool?

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw HelperError.serviceUnavailable }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw HelperError.openFailed(result) }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func setFanTarget(fanID: Int, rpm: Int) throws {
        guard fanID >= 0, fanID < readFanCount(), rpm >= 0, rpm <= 10000 else {
            throw HelperError.badCommand
        }
        try setFanForced(fanID: fanID)
        try writeFanTarget("F\(fanID)Tg", value: Double(rpm))
        manualControlActive = true
        lastHeartbeat = Date()
    }

    func resetFanControl() throws {
        if var ftst = try? readPayload(key: "Ftst"), !ftst.bytes.isEmpty {
            ftst.bytes[0] = 0
            try writeWithRetry(key: "Ftst", bytes: ftst.bytes, dataType: ftst.dataType, dataSize: ftst.dataSize)
        }

        for id in 0..<readFanCount() {
            let key = fanModeKey(id)
            guard var mode = try? readPayload(key: key), !mode.bytes.isEmpty else { continue }
            mode.bytes[0] = 0
            try? writeWithRetry(key: key, bytes: mode.bytes, dataType: mode.dataType, dataSize: mode.dataSize)
        }
        manualControlActive = false
        lastHeartbeat = Date.distantPast
    }

    private func readFanCount() -> Int {
        Int((try? readNumber("FNum")) ?? 0)
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

    private func readNumber(_ key: String) throws -> Double {
        let payload = try readPayload(key: key)
        let bytes = payload.bytes

        switch payload.dataType {
        case "ui8 ":
            guard let first = bytes.first else { throw HelperError.badData }
            return Double(first)
        case "fpe2":
            guard bytes.count >= 2 else { throw HelperError.badData }
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case "flt ":
            guard bytes.count >= 4 else { throw HelperError.badData }
            return Double(bytes.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float.self) })
        default:
            throw HelperError.badData
        }
    }

    private func readPayload(key: String) throws -> SMCPayload {
        var infoInput = SMCKeyData()
        infoInput.key = key.smcKey
        infoInput.data8 = SMCCommand.readKeyInfo.rawValue

        let infoOutput = try call(infoInput)
        let size = Int(infoOutput.keyInfo.dataSize)
        guard size > 0, size <= 32 else { throw HelperError.badData }

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
                if attempt < attempts - 1 { usleep(50_000) }
            }
        }
        throw lastError ?? HelperError.smcWriteRejected(key, 0xff)
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
            throw HelperError.smcWriteRejected(key, output.result)
        }
    }

    private func call(_ input: SMCKeyData) throws -> SMCKeyData {
        var input = input
        var output = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                inputPointer.withMemoryRebound(to: UInt8.self, capacity: inputSize) { inputBytes in
                    outputPointer.withMemoryRebound(to: UInt8.self, capacity: outputSize) { outputBytes in
                        IOConnectCallStructMethod(connection, 2, inputBytes, inputSize, outputBytes, &outputSize)
                    }
                }
            }
        }

        guard result == KERN_SUCCESS else { throw HelperError.callFailed(result) }
        return output
    }
}

private struct SMCPayload {
    var bytes: [UInt8]
    let dataType: String
    let dataSize: UInt32
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

private func handle(_ request: String) -> String {
    let parts = request.split(separator: " ").map(String.init)
    do {
        let smc = try FanPilotHelperSMC()
        if parts.count == 3, parts[0] == "set", let fanID = Int(parts[1]), let rpm = Int(parts[2]) {
            try smc.setFanTarget(fanID: fanID, rpm: rpm)
            return "OK set \(fanID) \(rpm)\n"
        }
        if parts.count == 1, parts[0] == "reset" {
            try smc.resetFanControl()
            return "OK reset\n"
        }
        if parts.count == 1, parts[0] == "heartbeat" {
            lastHeartbeat = Date()
            return "OK heartbeat\n"
        }
        return "ERR bad command\n"
    } catch {
        helperLog("ERROR request=\(request) error=\(error)")
        return "ERR \(error)\n"
    }
}

private func runServer() {
    helperLog("FanPilotHelper starting")
    unlink(socketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        helperLog("ERROR socket failed")
        fputs("socket failed\n", stderr)
        exit(1)
    }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    socketPath.withCString { pointer in
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
            let destination = rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self)
            strncpy(destination, pointer, rawBuffer.count - 1)
        }
    }

    let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length)
        }
    }
    guard bound == 0 else {
        helperLog("ERROR bind failed: \(String(cString: strerror(errno)))")
        fputs("bind failed: \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }

    chmod(socketPath, 0o666)
    guard listen(fd, 8) == 0 else {
        helperLog("ERROR listen failed")
        fputs("listen failed\n", stderr)
        exit(1)
    }
    helperLog("FanPilotHelper listening on \(socketPath)")

    DispatchQueue.global(qos: .utility).async {
        while true {
            sleep(2)
            guard manualControlActive, Date().timeIntervalSince(lastHeartbeat) > 8 else {
                continue
            }
            do {
                try FanPilotHelperSMC().resetFanControl()
                helperLog("Watchdog reset fan control")
                fputs("FanPilotHelper watchdog reset fan control\n", stderr)
            } catch {
                helperLog("ERROR watchdog reset failed: \(error)")
                fputs("FanPilotHelper watchdog reset failed: \(error)\n", stderr)
            }
        }
    }

    while true {
        let client = accept(fd, nil, nil)
        if client < 0 { continue }

        var buffer = [UInt8](repeating: 0, count: 256)
        let count = recv(client, &buffer, buffer.count, 0)
        let request = count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let response = handle(request)
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBytes {
            send(client, $0.baseAddress, bytes.count, 0)
        }
        close(client)
    }
}

runServer()
