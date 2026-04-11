import AppKit
import Foundation
import Security
import UserNotifications

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
    @Published var receiveStatus: ReceiveStatus = .idle
    @Published var fileUploadStatus: FileUploadStatus = .idle
    @Published var fileUploadProgress: Double = 0
    @Published var fileUploadSpeed: String = ""

    private let service = "com.copyeverywhere.relay"
    private let maxSmallFileSize: Int64 = 50 * 1024 * 1024 // 50MB
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

    enum ReceiveStatus: Equatable {
        case idle
        case receiving
        case success(String)
        case noContent
        case error(String)
    }

    enum FileUploadStatus: Equatable {
        case idle
        case uploading(filename: String)
        case success(clipID: String, filename: String, fileSize: String, expiresAt: String)
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

    // MARK: - Receive Operations

    func receiveLatest() async {
        receiveStatus = .receiving

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let metaURL = URL(string: "\(urlString)/api/v1/clips/latest") else {
            receiveStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: metaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                receiveStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let clipID = json["id"] as? String,
                      let clipType = json["type"] as? String else {
                    receiveStatus = .error("Unexpected response format")
                    return
                }

                if clipType == "text" {
                    await fetchAndCopyText(clipID: clipID)
                } else {
                    receiveStatus = .error("Latest clip is a \(clipType), not text")
                }
            case 404:
                receiveStatus = .noContent
            case 401:
                receiveStatus = .error("Authentication failed (401)")
            default:
                receiveStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                receiveStatus = .error("Connection refused - check server URL")
            case .timedOut:
                receiveStatus = .error("Request timed out")
            default:
                receiveStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            receiveStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    func receiveByID(_ clipID: String) async {
        receiveStatus = .receiving

        let trimmedID = clipID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            receiveStatus = .error("Please enter a Clip ID")
            return
        }

        await fetchAndCopyText(clipID: trimmedID)
    }

    // MARK: - File Upload

    func sendFile(url fileURL: URL) async {
        let filename = fileURL.lastPathComponent

        // Check file size
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            fileUploadStatus = .error("Cannot read file")
            return
        }

        if fileSize >= maxSmallFileSize {
            fileUploadStatus = .error("File is \(formatBytes(fileSize)) — files >= 50MB require chunked upload (coming soon)")
            return
        }

        guard let fileData = try? Data(contentsOf: fileURL) else {
            fileUploadStatus = .error("Cannot read file data")
            return
        }

        fileUploadStatus = .uploading(filename: filename)
        fileUploadProgress = 0
        fileUploadSpeed = ""

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let uploadURL = URL(string: "\(urlString)/api/v1/clips") else {
            fileUploadStatus = .error("Invalid server URL")
            return
        }

        // Determine type
        let clipType: String
        let mimeType: String
        let ext = fileURL.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp", "heic"].contains(ext) {
            clipType = "image"
            mimeType = "image/\(ext == "jpg" ? "jpeg" : ext)"
        } else {
            clipType = "file"
            mimeType = "application/octet-stream"
        }

        let boundary = UUID().uuidString
        var body = Data()

        // "type" field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"type\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(clipType)\r\n".data(using: .utf8)!)

        // "content" file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"content\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        // Write body to temp file for upload task (enables progress tracking)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try body.write(to: tempURL)
        } catch {
            fileUploadStatus = .error("Failed to prepare upload")
            return
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let delegate = UploadProgressDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let startTime = Date()
        let totalSize = Int64(body.count)

        // Progress tracking task
        let progressTask = Task {
            for await progress in delegate.progressStream {
                let elapsed = Date().timeIntervalSince(startTime)
                let bytesUploaded = Int64(Double(totalSize) * progress)
                let speed = elapsed > 0 ? Double(bytesUploaded) / elapsed : 0
                self.fileUploadProgress = progress
                self.fileUploadSpeed = "\(self.formatBytes(Int64(speed)))/s"
            }
        }

        do {
            let (data, response) = try await session.upload(for: request, fromFile: tempURL)
            progressTask.cancel()
            session.invalidateAndCancel()

            guard let httpResponse = response as? HTTPURLResponse else {
                fileUploadStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 201:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let clipID = json["id"] as? String,
                   let expiresAtStr = json["expires_at"] as? String {
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
                    fileUploadProgress = 1.0
                    fileUploadStatus = .success(
                        clipID: clipID,
                        filename: filename,
                        fileSize: formatBytes(fileSize),
                        expiresAt: expiryDisplay
                    )
                } else {
                    fileUploadStatus = .error("Unexpected response format")
                }
            case 401:
                fileUploadStatus = .error("Authentication failed (401)")
            case 413:
                fileUploadStatus = .error("File too large for server")
            default:
                fileUploadStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            progressTask.cancel()
            session.invalidateAndCancel()
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                fileUploadStatus = .error("Connection refused - check server URL")
            case .timedOut:
                fileUploadStatus = .error("Upload timed out")
            default:
                fileUploadStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            progressTask.cancel()
            session.invalidateAndCancel()
            fileUploadStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func fetchAndCopyText(clipID: String) async {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let rawURL = URL(string: "\(urlString)/api/v1/clips/\(clipID)/raw") else {
            receiveStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: rawURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                receiveStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 200:
                guard let text = String(data: data, encoding: .utf8) else {
                    receiveStatus = .error("Could not decode content as text")
                    return
                }

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)

                // Show macOS notification
                let content = UNMutableNotificationContent()
                content.title = "CopyEverywhere"
                content.body = "Copied to clipboard"
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)

                receiveStatus = .success(clipID)
            case 403:
                receiveStatus = .error("Upload incomplete - download unavailable")
            case 404:
                receiveStatus = .noContent
            case 401:
                receiveStatus = .error("Authentication failed (401)")
            default:
                receiveStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                receiveStatus = .error("Connection refused - check server URL")
            case .timedOut:
                receiveStatus = .error("Request timed out")
            default:
                receiveStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            receiveStatus = .error("Error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Upload Progress Delegate

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let continuation: AsyncStream<Double>.Continuation
    let progressStream: AsyncStream<Double>

    override init() {
        var cont: AsyncStream<Double>.Continuation!
        progressStream = AsyncStream { cont = $0 }
        continuation = cont
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        continuation.yield(progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish()
    }
}
