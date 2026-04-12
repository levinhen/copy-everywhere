import Foundation

/// Server configuration — stub for US-069, full implementation in US-070.
@MainActor
final class ServerConfig: ObservableObject {
    /// Environment variables forwarded to the Go server subprocess.
    var environment: [String: String] {
        [:]
    }
}
