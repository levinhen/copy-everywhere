import AppKit
import Foundation
import Security

struct ClipResult {
    let id: String
    let expiresAt: Date
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published var hostURL: String = ""
    @Published var accessToken: String = ""
    @Published var isConfigured: Bool = false
    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var sendStatus: SendStatus = .idle

    private let service = "com.copyeverywhere.relay"
    private let hostKey = "hostURL"
    private let tokenKey = "accessToken"

    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case success(latencyMs: Int)
        case error(String)
    }

    enum SendStatus: Equatable {
        case idle
        case sending
        case success(clipID: String, expiresAt: String)
        case error(String)
    }

    init() {
        loadFromKeychain()
    }

    // MARK: - Keychain Operations

    func save() {
        saveToKeychain(account: hostKey, value: hostURL)
        saveToKeychain(account: tokenKey, value: accessToken)
        isConfigured = !hostURL.isEmpty && !accessToken.isEmpty
    }

    func clearConfig() {
        deleteFromKeychain(account: hostKey)
        deleteFromKeychain(account: tokenKey)
        hostURL = ""
        accessToken = ""
        isConfigured = false
        connectionStatus = .idle
    }

    private func loadFromKeychain() {
        hostURL = readFromKeychain(account: hostKey) ?? ""
        accessToken = readFromKeychain(account: tokenKey) ?? ""
        isConfigured = !hostURL.isEmpty && !accessToken.isEmpty
    }

    private func saveToKeychain(account: String, value: String) {
        let data = Data(value.utf8)

        // Delete existing item first
        deleteFromKeychain(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    private func readFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Test Connection

    func testConnection() async {
        connectionStatus = .testing

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/health") else {
            connectionStatus = .error("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let start = Date()

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                connectionStatus = .error("Invalid response")
                return
            }

            let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

            switch httpResponse.statusCode {
            case 200:
                connectionStatus = .success(latencyMs: latencyMs)
            case 401:
                connectionStatus = .error("Authentication failed (401) - check your access token")
            default:
                connectionStatus = .error("Server returned status \(httpResponse.statusCode)")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                connectionStatus = .error("Connection refused - check the server URL")
            case .timedOut:
                connectionStatus = .error("Connection timed out - server may be unreachable")
            case .secureConnectionFailed:
                connectionStatus = .error("TLS/SSL connection failed - check server certificate")
            default:
                connectionStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            connectionStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Clipboard Operations

    func getClipboardText() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }

    func sendClipboardText() async {
        guard let text = getClipboardText(), !text.isEmpty else {
            sendStatus = .error("Clipboard is empty")
            return
        }

        sendStatus = .sending

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/api/v1/clips") else {
            sendStatus = .error("Invalid server URL")
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Build multipart body
        var body = Data()
        let textData = Data(text.utf8)

        // "type" field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"type\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        // "content" file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"content\"; filename=\"clipboard.txt\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/plain\r\n\r\n".data(using: .utf8)!)
        body.append(textData)
        body.append("\r\n".data(using: .utf8)!)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                sendStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 201:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let clipID = json["id"] as? String,
                   let expiresAtStr = json["expires_at"] as? String {
                    // Format the expiry for display
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let displayFormatter = DateFormatter()
                    displayFormatter.dateStyle = .none
                    displayFormatter.timeStyle = .short

                    var expiryDisplay = expiresAtStr
                    if let date = formatter.date(from: expiresAtStr) {
                        displayFormatter.timeZone = .current
                        expiryDisplay = displayFormatter.string(from: date)
                    }
                    sendStatus = .success(clipID: clipID, expiresAt: expiryDisplay)
                } else {
                    sendStatus = .error("Unexpected response format")
                }
            case 401:
                sendStatus = .error("Authentication failed (401)")
            case 413:
                sendStatus = .error("Content too large")
            default:
                sendStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                sendStatus = .error("Connection refused - check server URL")
            case .timedOut:
                sendStatus = .error("Request timed out")
            default:
                sendStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            sendStatus = .error("Error: \(error.localizedDescription)")
        }
    }
}
