import Darwin
import Foundation

enum HelperClientError: Error {
    case socketFailed
    case connectFailed(String)
    case sendFailed
    case emptyResponse
    case helperError(String)
}

enum HelperClient {
    private static let socketPath = "/tmp/fanpilot-helper.sock"

    static func setFanTarget(fanID: Int, rpm: Int) throws {
        try send("set \(fanID) \(rpm)\n")
    }

    static func resetFanControl() throws {
        try send("reset\n")
    }

    static func heartbeat() throws {
        try send("heartbeat\n")
    }

    private static func send(_ command: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperClientError.socketFailed }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { pointer in
            guard strlen(pointer) < MemoryLayout.size(ofValue: address.sun_path) else {
                throw HelperClientError.connectFailed("socket path too long")
            }
            withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
                let destination = rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                strncpy(destination, pointer, rawBuffer.count - 1)
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, length)
            }
        }
        guard connected == 0 else {
            throw HelperClientError.connectFailed(String(cString: strerror(errno)))
        }

        let bytes = Array(command.utf8)
        let sent = bytes.withUnsafeBytes {
            Darwin.send(fd, $0.baseAddress, bytes.count, 0)
        }
        guard sent == bytes.count else { throw HelperClientError.sendFailed }

        var buffer = [UInt8](repeating: 0, count: 512)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { throw HelperClientError.emptyResponse }

        let response = String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if response.hasPrefix("OK") { return }
        throw HelperClientError.helperError(response)
    }
}
