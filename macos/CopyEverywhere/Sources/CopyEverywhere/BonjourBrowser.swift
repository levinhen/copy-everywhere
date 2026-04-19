import Foundation
import Network

// LAN discovery contract for this iteration lives in `tasks/lan-discovery-selection-contract.md`
// and is tracked by Ralph in `scripts/ralph/prd.json` / `scripts/ralph/progress.txt`.
enum LanEndpointSource: String, Codable, CaseIterable {
    case autoDiscovered = "auto_discovered"
    case restoredSelection = "restored_selection"
    case manualFallback = "manual_fallback"
}

struct StoredLanServerSelection: Codable, Equatable {
    let serverID: String
    let name: String
    let host: String
    let port: UInt16
    let source: LanEndpointSource
}

struct DiscoveredServer: Identifiable, Equatable, Hashable {
    let id: String // Display identity only. Persistent selection must use `serverID`.
    let serverID: String?
    let name: String
    let host: String
    let port: UInt16
    let authRequired: Bool
    let version: String

    static func == (lhs: DiscoveredServer, rhs: DiscoveredServer) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var endpointURLString: String {
        "http://\(host):\(port)"
    }
}

@MainActor
final class BonjourBrowser: ObservableObject {
    @Published var discoveredServers: [DiscoveredServer] = []
    @Published var isSearching: Bool = false

    private var browser: NWBrowser?
    private var connections: [NWConnection] = []

    func startBrowsing() {
        stopBrowsing()

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_copyeverywhere._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                case .failed, .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.handleResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
        isSearching = true
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        // Resolve each result to get endpoint details
        for result in results {
            resolveEndpoint(result)
        }

        // Remove servers whose endpoints are no longer in the results
        let currentEndpointNames = Set(results.compactMap { result -> String? in
            if case .service(let name, _, _, _) = result.endpoint {
                return name
            }
            return nil
        })

        discoveredServers.removeAll { server in
            !currentEndpointNames.contains(server.name)
        }
    }

    private func resolveEndpoint(_ result: NWBrowser.Result) {
        // Extract TXT record metadata
        var authRequired = false
        var version = ""
        var serverID: String?

        if case .bonjour(let txtRecord) = result.metadata {
            if let authValue = txtRecord.stringValue(for: "auth") {
                authRequired = authValue == "true"
            }
            if let versionValue = txtRecord.stringValue(for: "version") {
                version = versionValue
            }
            serverID = txtRecord.stringValue(for: "server_id")
        }

        guard case .service(let name, _, _, _) = result.endpoint else { return }

        // Use NWConnection to resolve the service endpoint to a host:port
        let params = NWParameters.tcp
        let connection = NWConnection(to: result.endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .ready:
                    if let innerEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = innerEndpoint {
                        let hostStr = self.hostString(from: host)
                        let portNum = port.rawValue
                        let server = DiscoveredServer(
                            id: "\(hostStr):\(portNum)",
                            serverID: serverID,
                            name: name,
                            host: hostStr,
                            port: portNum,
                            authRequired: authRequired,
                            version: version
                        )
                        if let idx = self.discoveredServers.firstIndex(where: { $0.name == name }) {
                            self.discoveredServers[idx] = server
                        } else {
                            self.discoveredServers.append(server)
                        }
                    }
                    connection.cancel()
                    self.connections.removeAll { $0 === connection }
                case .failed, .cancelled:
                    self.connections.removeAll { $0 === connection }
                default:
                    break
                }
            }
        }

        connections.append(connection)
        connection.start(queue: .main)
    }

    private func hostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr):
            return "\(addr)"
        case .ipv6(let addr):
            return "\(addr)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}

// MARK: - TXT Record helper

private extension NWTXTRecord {
    func stringValue(for key: String) -> String? {
        let entry: NWTXTRecord.Entry? = getEntry(for: key)
        guard let entry = entry else { return nil }
        switch entry {
        case .string(let value):
            return value
        case .none, .empty:
            return nil
        case .data(let data):
            return String(data: Data(data), encoding: .utf8)
        @unknown default:
            return nil
        }
    }
}
