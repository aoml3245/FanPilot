import Foundation
import IOKit

enum WriteTestCommand {
    static func run() {
        do {
            let fanID = argument(after: "--fan").flatMap(Int.init) ?? 0
            let smc = try SMC()
            let fans = try smc.readFans()
            guard let fan = fans.first(where: { $0.id == fanID }) else {
                throw WriteTestError.failed("fan \(fanID) not found")
            }

            let requestedRPM = argument(after: "--rpm").flatMap(Int.init) ?? fan.targetRPM ?? fan.actualRPM
            print("FanPilot write test")
            print("fan: \(fan.id) \(fan.name)")
            print("actual: \(fan.actualRPM) RPM")
            print("target before: \(fan.targetRPM ?? -1) RPM")
            print("range: \(fan.minimumRPM)-\(fan.maximumRPM) RPM")
            print("requested write: \(requestedRPM) RPM")

            let rpm = fan.clampedRPM(requestedRPM)
            do {
                try smc.setFanTarget(fanID: fanID, rpm: rpm)
                print("write path: direct")
            } catch SMCError.callFailed(let code) where code == kIOReturnNotPrivileged {
                try HelperClient.setFanTarget(fanID: fanID, rpm: rpm)
                print("write path: privileged helper")
            }
            usleep(300_000)

            let after = try smc.readFans().first { $0.id == fanID }
            print("target after: \(after?.targetRPM ?? -1) RPM")
            print("actual after: \(after?.actualRPM ?? -1) RPM")
            print("write test passed")
        } catch {
            fputs("FanPilot write test failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func argument(after key: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: key) else { return nil }
        let next = CommandLine.arguments.index(after: index)
        guard CommandLine.arguments.indices.contains(next) else { return nil }
        return CommandLine.arguments[next]
    }
}

enum WriteTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}
