import Foundation

/// Persists server configuration to a JSON file in Application Support.
@MainActor
final class ServerConfig: ObservableObject {
    @Published var port: String = "8080"
    @Published var storagePath: String = ""
    @Published var ttlHours: Int = 1
    @Published var authEnabled: Bool = false
    @Published var accessToken: String = ""

    /// Computed status fields (updated by polling /health or filesystem)
    @Published var usedSpaceBytes: Int64 = 0

    private let configURL: URL

    static let defaultStoragePath: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("CopyEverywhereServer/data").path
    }()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configDir = appSupport.appendingPathComponent("CopyEverywhereServer")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        configURL = configDir.appendingPathComponent("config.json")
        load()
        if storagePath.isEmpty {
            storagePath = Self.defaultStoragePath
        }
    }

    /// Environment variables to forward to the Go server subprocess.
    var environment: [String: String] {
        var env: [String: String] = [
            "PORT": port,
            "STORAGE_PATH": storagePath,
            "TTL_HOURS": String(ttlHours),
            "AUTH_ENABLED": authEnabled ? "true" : "false",
        ]
        if authEnabled && !accessToken.isEmpty {
            env["ACCESS_TOKEN"] = accessToken
        }
        return env
    }

    // MARK: - Persistence

    func save() {
        let data = ConfigData(
            port: port,
            storagePath: storagePath,
            ttlHours: ttlHours,
            authEnabled: authEnabled,
            accessToken: accessToken
        )
        do {
            let json = try JSONEncoder().encode(data)
            try json.write(to: configURL, options: .atomic)
        } catch {
            print("[ServerConfig] Failed to save: \(error)")
        }
    }

    private func load() {
        guard let json = try? Data(contentsOf: configURL),
              let data = try? JSONDecoder().decode(ConfigData.self, from: json) else { return }
        port = data.port
        storagePath = data.storagePath
        ttlHours = data.ttlHours
        authEnabled = data.authEnabled
        accessToken = data.accessToken
    }

    // MARK: - Storage usage

    func refreshUsedSpace() {
        let path = storagePath
        Task.detached {
            let bytes = ServerConfig.calculateDirectorySize(atPath: path)
            await MainActor.run { self.usedSpaceBytes = bytes }
        }
    }

    private nonisolated static func calculateDirectorySize(atPath path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let full = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }
}

// MARK: - Codable model

private struct ConfigData: Codable {
    var port: String
    var storagePath: String
    var ttlHours: Int
    var authEnabled: Bool
    var accessToken: String
}
