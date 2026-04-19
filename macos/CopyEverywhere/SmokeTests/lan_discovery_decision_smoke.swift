import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func makeServer(serverID: String, host: String, port: UInt16) -> DiscoveredServer {
    DiscoveredServer(
        id: "\(host):\(port)",
        serverID: serverID,
        name: "Server \(serverID)",
        host: host,
        port: port,
        authRequired: false,
        version: "0.1.0"
    )
}

@main
struct LanDiscoveryDecisionSmokeRunner {
    static func main() {
        let uniqueServer = makeServer(serverID: "srv-1", host: "192.168.1.20", port: 8080)
        expect(
            LanDiscoveryDecision.decide(
                servers: [uniqueServer],
                selectedServer: nil,
                source: .manualFallback,
                currentHostURL: ""
            ) == .autoSelect(uniqueServer),
            "unique discovered server should auto-select"
        )

        let restoredSelection = StoredLanServerSelection(
            serverID: "srv-1",
            name: "Office Mac",
            host: "192.168.1.20",
            port: 8080,
            source: .restoredSelection
        )
        let rediscoveredServer = makeServer(serverID: "srv-1", host: "192.168.1.44", port: 8080)
        expect(
            LanDiscoveryDecision.decide(
                servers: [rediscoveredServer],
                selectedServer: restoredSelection,
                source: .restoredSelection,
                currentHostURL: "http://192.168.1.20:8080"
            ) == .restore(rediscoveredServer),
            "persisted server_id should restore after host change"
        )

        expect(
            LanDiscoveryDecision.decide(
                servers: [
                    makeServer(serverID: "srv-1", host: "192.168.1.20", port: 8080),
                    makeServer(serverID: "srv-2", host: "192.168.1.21", port: 8080),
                ],
                selectedServer: nil,
                source: .manualFallback,
                currentHostURL: ""
            ) == .waitForSelection,
            "multiple discovered servers should wait for explicit selection"
        )

        expect(
            LanDiscoveryDecision.decide(
                servers: [],
                selectedServer: restoredSelection,
                source: .restoredSelection,
                currentHostURL: "http://192.168.1.20:8080"
            ) == .preserveManualFallback,
            "missing discovered server should preserve manual fallback"
        )

        print("LanDiscoveryDecision smoke tests passed")
    }
}
