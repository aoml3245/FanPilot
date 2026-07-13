import Foundation

enum ProbeCommand {
    struct Snapshot: Codable {
        let fans: [Fan]
        let sensors: [Sensor]
        let writesEnabled: Bool
    }

    static func run() {
        do {
            let smc = try SMC()
            let snapshot = Snapshot(
                fans: try smc.readFans(),
                sensors: try smc.readSensors(),
                writesEnabled: false
            )
            let data = try JSONEncoder.pretty.encode(snapshot)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("FanPilot probe failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
