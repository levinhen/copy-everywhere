import Foundation

enum LanDiscoveryDecision: Equatable {
    case none
    case waitForSelection
    case preserveManualFallback
    case autoSelect(DiscoveredServer)
    case restore(DiscoveredServer)

    static func decide(
        servers: [DiscoveredServer],
        selectedServer: StoredLanServerSelection?,
        source: LanEndpointSource,
        currentHostURL: String
    ) -> LanDiscoveryDecision {
        if let selectedServer {
            if let restored = servers.first(where: { $0.serverID == selectedServer.serverID }) {
                return .restore(restored)
            }

            return source == .manualFallback ? .none : .preserveManualFallback
        }

        let trimmedHostURL = currentHostURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard trimmedHostURL.isEmpty else { return .none }

        if servers.count == 1, let server = servers.first {
            return .autoSelect(server)
        }

        if servers.count > 1 {
            return .waitForSelection
        }

        return .none
    }
}
