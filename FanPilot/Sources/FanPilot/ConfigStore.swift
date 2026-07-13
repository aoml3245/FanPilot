import Foundation

final class ConfigStore {
    private let url: URL
    private let saveQueue = DispatchQueue(label: "FanPilot.ConfigStore.save")

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("FanPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("config.json")
    }

    func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: url) else {
            return AppConfiguration()
        }

        do {
            return try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch {
            return AppConfiguration()
        }
    }

    func save(_ configuration: AppConfiguration) {
        let url = url
        saveQueue.async {
            do {
                let data = try JSONEncoder.pretty.encode(configuration)
                try data.write(to: url, options: [.atomic])
            } catch {
                AppLog.error("Config save failed: \(error)")
                NSLog("FanPilot config save failed: \(error)")
            }
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
