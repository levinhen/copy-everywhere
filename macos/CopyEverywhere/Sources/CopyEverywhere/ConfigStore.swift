import AppKit
import Foundation
import Security
import UserNotifications

struct ClipResult {
    let id: String
    let expiresAt: Date
}

struct DeviceInfo: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let platform: String
    let lastSeenAt: Date
}

struct QueueItem: Identifiable, Equatable {
    let id: String
    let type: String
    let filename: String?
    let sizeBytes: Int64
    let createdAt: Date
    let expiresAt: Date

    var typeIcon: String {
        switch type {
        case "text": return "doc.text"
        case "image": return "photo"
        default: return "doc"
        }
    }

    var preview: String {
        if let filename = filename, filename != "clipboard.txt" {
            return filename
        }
        if type == "text" { return "Text clip" }
        if type == "image" { return "Image" }
        return filename ?? "File"
    }

    var age: String {
        let interval = Date().timeIntervalSince(createdAt)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
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
    @Published var fileDownloadStatus: FileDownloadStatus = .idle
    @Published var fileDownloadProgress: Double = 0
    @Published var fileDownloadSpeed: String = ""
    @Published var deviceID: String = ""
    @Published var deviceName: String = ""
    @Published var toastMessage: String? = nil
    @Published var queueItems: [QueueItem] = []
    @Published var queueError: String? = nil
    @Published var availableDevices: [DeviceInfo] = []
    @Published var targetDeviceID: String? = nil  // nil means "Queue — any device"

    // SSE state
    private var sseTask: Task<Void, Never>?
    private var sseRetryDelay: TimeInterval = 1.0
    private let sseMaxRetryDelay: TimeInterval = 30.0

    private let service = "com.copyeverywhere.relay"
    private let maxSmallFileSize: Int64 = 50 * 1024 * 1024 // 50MB
    private let chunkSize: Int64 = 10 * 1024 * 1024 // 10MB chunks
    private let hostKey = "hostURL"
    private let tokenKey = "accessToken"

    // Chunked upload state
    private var chunkedUploadID: String?
    private var chunkedUploadFileURL: URL?
    private var chunkedUploadTask: Task<Void, Never>?
    private var chunkedIsPaused = false

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
        case chunkedUploading(filename: String, currentChunk: Int, totalChunks: Int)
        case chunkedPaused(filename: String, currentChunk: Int, totalChunks: Int)
        case success(clipID: String, filename: String, fileSize: String, expiresAt: String)
        case error(String)
    }

    struct ClipMetadata: Equatable {
        let id: String
        let type: String
        let filename: String?
        let sizeBytes: Int64
        let createdAt: String
        let expiresAt: String
    }

    enum FileDownloadStatus: Equatable {
        case idle
        case fetchingMetadata
        case metadataLoaded(ClipMetadata)
        case downloading(filename: String)
        case success(savedPath: String)
        case uploadIncomplete
        case error(String)
    }

    init() {
        loadFromKeychain()
        deviceID = UserDefaults.standard.string(forKey: "com.copyeverywhere.deviceID") ?? ""
        deviceName = UserDefaults.standard.string(forKey: "com.copyeverywhere.deviceName") ?? ""
    }

    // MARK: - Keychain Operations

    func save() {
        saveToKeychain(account: hostKey, value: hostURL)
        saveToKeychain(account: tokenKey, value: accessToken)
        isConfigured = !hostURL.isEmpty && !accessToken.isEmpty
        if isConfigured {
            Task {
                await registerDevice()
                // Restart SSE with new credentials
                stopSSE()
                startSSE()
            }
        }
    }

    func registerDevice() async {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(urlString)/api/v1/devices/register") else { return }

        let name = Host.current().localizedName ?? "Mac"
        let payload: [String: String] = ["name": name, "platform": "macos"]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = json["device_id"] as? String {
                deviceID = id
                deviceName = name
                UserDefaults.standard.set(id, forKey: "com.copyeverywhere.deviceID")
                UserDefaults.standard.set(name, forKey: "com.copyeverywhere.deviceName")
            }
        } catch {
            // Registration is best-effort — don't block the save flow
        }
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

        // Device ID fields
        appendDeviceFields(to: &body, boundary: boundary)

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
                    var expiryDate = Date().addingTimeInterval(3600) // fallback
                    if let date = formatter.date(from: expiresAtStr) {
                        displayFormatter.timeZone = .current
                        expiryDisplay = displayFormatter.string(from: date)
                        expiryDate = date
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

    /// Fire-and-forget text send for drag-and-drop (does not touch sendStatus).
    func sendText(_ text: String) async -> (success: Bool, message: String) {
        guard isConfigured else { return (false, "Not configured") }

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(urlString)/api/v1/clips") else {
            return (false, "Invalid server URL")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        let textData = Data(text.utf8)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"type\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"content\"; filename=\"clipboard.txt\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: text/plain\r\n\r\n".data(using: .utf8)!)
        body.append(textData)
        body.append("\r\n".data(using: .utf8)!)

        // Device ID fields
        appendDeviceFields(to: &body, boundary: boundary)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Invalid response")
            }
            if httpResponse.statusCode == 201 {
                return (true, "text (\(text.count) chars)")
            }
            return (false, "Server error (\(httpResponse.statusCode))")
        } catch {
            return (false, error.localizedDescription)
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
            await sendFileChunked(url: fileURL, filename: filename, fileSize: fileSize)
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

        // Device ID fields
        appendDeviceFields(to: &body, boundary: boundary)

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
                    var expiryDate = Date().addingTimeInterval(3600)
                    if let date = formatter.date(from: expiresAtStr) {
                        displayFormatter.timeZone = .current
                        expiryDisplay = displayFormatter.string(from: date)
                        expiryDate = date
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

    // MARK: - Chunked Upload

    func sendFileChunked(url fileURL: URL, filename: String, fileSize: Int64) async {
        chunkedIsPaused = false
        chunkedUploadFileURL = fileURL

        let totalChunks = Int((fileSize + chunkSize - 1) / chunkSize)

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Step 1: Init upload
        guard let initURL = URL(string: "\(urlString)/api/v1/uploads/init") else {
            fileUploadStatus = .error("Invalid server URL")
            return
        }

        var initRequest = URLRequest(url: initURL)
        initRequest.httpMethod = "POST"
        initRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        initRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initRequest.timeoutInterval = 30

        var initBody: [String: Any] = [
            "filename": filename,
            "size_bytes": fileSize,
            "chunk_size": chunkSize
        ]
        if !deviceID.isEmpty {
            initBody["sender_device_id"] = deviceID
        }
        if let targetID = targetDeviceID {
            initBody["target_device_id"] = targetID
        }
        initRequest.httpBody = try? JSONSerialization.data(withJSONObject: initBody)

        do {
            let (data, response) = try await URLSession.shared.data(for: initRequest)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 401 {
                    fileUploadStatus = .error("Authentication failed (401)")
                } else if statusCode == 413 {
                    fileUploadStatus = .error("File too large for server")
                } else {
                    fileUploadStatus = .error("Failed to init upload (status \(statusCode))")
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploadID = json["upload_id"] as? String else {
                fileUploadStatus = .error("Invalid init response")
                return
            }

            chunkedUploadID = uploadID
            await uploadChunks(uploadID: uploadID, fileURL: fileURL, filename: filename, fileSize: fileSize, totalChunks: totalChunks, startChunk: 1)
        } catch {
            fileUploadStatus = .error("Network error: \(error.localizedDescription)")
        }
    }

    func pauseChunkedUpload() {
        chunkedIsPaused = true
        chunkedUploadTask?.cancel()
        chunkedUploadTask = nil
        if case .chunkedUploading(let filename, let chunk, let total) = fileUploadStatus {
            fileUploadStatus = .chunkedPaused(filename: filename, currentChunk: chunk, totalChunks: total)
        }
    }

    func resumeChunkedUpload() async {
        guard let uploadID = chunkedUploadID,
              let fileURL = chunkedUploadFileURL else {
            fileUploadStatus = .error("No upload to resume")
            return
        }

        let filename = fileURL.lastPathComponent
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            fileUploadStatus = .error("Cannot read file")
            return
        }

        let totalChunks = Int((fileSize + chunkSize - 1) / chunkSize)

        // Query server for received parts
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let statusURL = URL(string: "\(urlString)/api/v1/uploads/\(uploadID)/status") else {
            fileUploadStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: statusURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                fileUploadStatus = .error("Failed to check upload status (\(statusCode))")
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let receivedParts = json["received_parts"] as? [Int] else {
                fileUploadStatus = .error("Invalid status response")
                return
            }

            let receivedSet = Set(receivedParts)
            // Find first missing chunk (1-indexed)
            var startChunk = 1
            for i in 1...totalChunks {
                if !receivedSet.contains(i) {
                    startChunk = i
                    break
                }
            }

            chunkedIsPaused = false
            await uploadChunks(uploadID: uploadID, fileURL: fileURL, filename: filename, fileSize: fileSize, totalChunks: totalChunks, startChunk: startChunk, receivedParts: receivedSet)
        } catch {
            fileUploadStatus = .error("Network error: \(error.localizedDescription)")
        }
    }

    private func uploadChunks(uploadID: String, fileURL: URL, filename: String, fileSize: Int64, totalChunks: Int, startChunk: Int, receivedParts: Set<Int> = []) async {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            fileUploadStatus = .error("Cannot open file")
            return
        }
        defer { try? fileHandle.close() }

        let startTime = Date()

        for chunkIndex in startChunk...totalChunks {
            if chunkedIsPaused || Task.isCancelled {
                return
            }

            // Skip already-received parts
            if receivedParts.contains(chunkIndex) {
                continue
            }

            fileUploadStatus = .chunkedUploading(filename: filename, currentChunk: chunkIndex, totalChunks: totalChunks)
            fileUploadProgress = Double(chunkIndex - 1) / Double(totalChunks)

            // Read chunk data
            let offset = Int64(chunkIndex - 1) * chunkSize
            try? fileHandle.seek(toOffset: UInt64(offset))
            let readSize = min(chunkSize, fileSize - offset)
            guard let chunkData = try? fileHandle.read(upToCount: Int(readSize)), !chunkData.isEmpty else {
                fileUploadStatus = .error("Failed to read chunk \(chunkIndex)")
                return
            }

            // Upload chunk
            guard let partURL = URL(string: "\(urlString)/api/v1/uploads/\(uploadID)/parts/\(chunkIndex)") else {
                fileUploadStatus = .error("Invalid server URL")
                return
            }

            var request = URLRequest(url: partURL)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120
            request.httpBody = chunkData

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    fileUploadStatus = .error("Invalid response for chunk \(chunkIndex)")
                    return
                }

                if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 && httpResponse.statusCode != 409 {
                    fileUploadStatus = .error("Failed to upload chunk \(chunkIndex) (status \(httpResponse.statusCode))")
                    return
                }

                // Update speed
                let elapsed = Date().timeIntervalSince(startTime)
                let bytesUploaded = Int64(chunkIndex) * chunkSize
                let speed = elapsed > 0 ? Double(bytesUploaded) / elapsed : 0
                fileUploadSpeed = "\(formatBytes(Int64(speed)))/s"
                fileUploadProgress = Double(chunkIndex) / Double(totalChunks)
            } catch {
                if chunkedIsPaused || Task.isCancelled {
                    return
                }
                fileUploadStatus = .error("Network error on chunk \(chunkIndex): \(error.localizedDescription)")
                return
            }
        }

        if chunkedIsPaused || Task.isCancelled {
            return
        }

        // Step 3: Complete upload
        guard let completeURL = URL(string: "\(urlString)/api/v1/uploads/\(uploadID)/complete") else {
            fileUploadStatus = .error("Invalid server URL")
            return
        }

        var completeRequest = URLRequest(url: completeURL)
        completeRequest.httpMethod = "POST"
        completeRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        completeRequest.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: completeRequest)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                fileUploadStatus = .error("Failed to complete upload (status \(statusCode))")
                return
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let clipID = json["id"] as? String,
               let expiresAtStr = json["expires_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let displayFormatter = DateFormatter()
                displayFormatter.dateStyle = .none
                displayFormatter.timeStyle = .short

                var expiryDisplay = expiresAtStr
                var expiryDate = Date().addingTimeInterval(3600)
                if let date = formatter.date(from: expiresAtStr) {
                    displayFormatter.timeZone = .current
                    expiryDisplay = displayFormatter.string(from: date)
                    expiryDate = date
                }
                fileUploadProgress = 1.0
                fileUploadStatus = .success(
                    clipID: clipID,
                    filename: filename,
                    fileSize: formatBytes(fileSize),
                    expiresAt: expiryDisplay
                )
            } else {
                fileUploadStatus = .error("Unexpected complete response format")
            }
        } catch {
            fileUploadStatus = .error("Network error completing upload: \(error.localizedDescription)")
        }

        // Clear chunked state on success
        chunkedUploadID = nil
        chunkedUploadFileURL = nil
    }

    // MARK: - File Download

    func fetchClipMetadata(_ clipID: String) async {
        let trimmedID = clipID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            fileDownloadStatus = .error("Please enter a Clip ID")
            return
        }

        fileDownloadStatus = .fetchingMetadata

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let metaURL = URL(string: "\(urlString)/api/v1/clips/\(trimmedID)") else {
            fileDownloadStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: metaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                fileDownloadStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String,
                      let type = json["type"] as? String,
                      let sizeBytes = json["size_bytes"] as? Int64,
                      let createdAtStr = json["created_at"] as? String,
                      let expiresAtStr = json["expires_at"] as? String else {
                    fileDownloadStatus = .error("Unexpected response format")
                    return
                }

                let filename = json["filename"] as? String

                // Format dates for display
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let displayFormatter = DateFormatter()
                displayFormatter.dateStyle = .short
                displayFormatter.timeStyle = .short
                displayFormatter.timeZone = .current

                var createdDisplay = createdAtStr
                if let date = isoFormatter.date(from: createdAtStr) {
                    createdDisplay = displayFormatter.string(from: date)
                }

                var expiresDisplay = expiresAtStr
                if let date = isoFormatter.date(from: expiresAtStr) {
                    expiresDisplay = displayFormatter.string(from: date)
                }

                fileDownloadStatus = .metadataLoaded(ClipMetadata(
                    id: id,
                    type: type,
                    filename: filename,
                    sizeBytes: sizeBytes,
                    createdAt: createdDisplay,
                    expiresAt: expiresDisplay
                ))
            case 404:
                fileDownloadStatus = .error("Clip not found or expired")
            case 401:
                fileDownloadStatus = .error("Authentication failed (401)")
            default:
                fileDownloadStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                fileDownloadStatus = .error("Connection refused - check server URL")
            case .timedOut:
                fileDownloadStatus = .error("Request timed out")
            default:
                fileDownloadStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            fileDownloadStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    func downloadFile(clipID: String, saveURL: URL) async {
        guard case .metadataLoaded(let meta) = fileDownloadStatus else { return }

        let filename = meta.filename ?? "\(clipID)"
        fileDownloadStatus = .downloading(filename: filename)
        fileDownloadProgress = 0
        fileDownloadSpeed = ""

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let rawURL = URL(string: "\(urlString)/api/v1/clips/\(clipID)/raw") else {
            fileDownloadStatus = .error("Invalid server URL")
            return
        }

        var request = URLRequest(url: rawURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300

        let delegate = DownloadProgressDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let startTime = Date()

        // Progress tracking task
        let progressTask = Task {
            for await (written, total) in delegate.progressStream {
                let elapsed = Date().timeIntervalSince(startTime)
                let speed = elapsed > 0 ? Double(written) / elapsed : 0
                if total > 0 {
                    self.fileDownloadProgress = Double(written) / Double(total)
                }
                self.fileDownloadSpeed = "\(self.formatBytes(Int64(speed)))/s"
            }
        }

        do {
            let (tempURL, response) = try await session.download(for: request)
            progressTask.cancel()
            session.invalidateAndCancel()

            guard let httpResponse = response as? HTTPURLResponse else {
                fileDownloadStatus = .error("Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 200:
                // Move downloaded file to save location
                let fileManager = FileManager.default
                // Remove existing file if present
                if fileManager.fileExists(atPath: saveURL.path) {
                    try fileManager.removeItem(at: saveURL)
                }
                try fileManager.moveItem(at: tempURL, to: saveURL)

                fileDownloadProgress = 1.0
                fileDownloadStatus = .success(savedPath: saveURL.path)

                // Reveal in Finder
                NSWorkspace.shared.activateFileViewerSelecting([saveURL])
            case 403:
                fileDownloadStatus = .uploadIncomplete
            case 404:
                fileDownloadStatus = .error("Clip not found or expired")
            case 401:
                fileDownloadStatus = .error("Authentication failed (401)")
            default:
                fileDownloadStatus = .error("Server error (\(httpResponse.statusCode))")
            }
        } catch let error as URLError {
            progressTask.cancel()
            session.invalidateAndCancel()
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost:
                fileDownloadStatus = .error("Connection refused - check server URL")
            case .timedOut:
                fileDownloadStatus = .error("Download timed out")
            default:
                fileDownloadStatus = .error("Network error: \(error.localizedDescription)")
            }
        } catch {
            progressTask.cancel()
            session.invalidateAndCancel()
            fileDownloadStatus = .error("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Queue Operations

    func fetchQueue() async {
        guard isConfigured, !deviceID.isEmpty else { return }

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/api/v1/clips?device_id=\(deviceID)") else {
            queueError = "Invalid server URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                queueError = "Invalid response"
                return
            }

            if httpResponse.statusCode == 200 {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

                guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    queueError = "Unexpected response format"
                    return
                }

                var items: [QueueItem] = []
                for json in jsonArray {
                    guard let id = json["id"] as? String,
                          let type = json["type"] as? String,
                          let sizeBytes = json["size_bytes"] as? Int64,
                          let createdAtStr = json["created_at"] as? String,
                          let expiresAtStr = json["expires_at"] as? String else { continue }

                    let filename = json["filename"] as? String
                    let createdAt = isoFormatter.date(from: createdAtStr) ?? Date()
                    let expiresAt = isoFormatter.date(from: expiresAtStr) ?? Date()

                    items.append(QueueItem(
                        id: id, type: type, filename: filename,
                        sizeBytes: sizeBytes, createdAt: createdAt, expiresAt: expiresAt
                    ))
                }
                queueItems = items
                queueError = nil
            } else if httpResponse.statusCode == 401 {
                queueError = "Authentication failed (401)"
            } else {
                queueError = "Server error (\(httpResponse.statusCode))"
            }
        } catch {
            queueError = "Network error: \(error.localizedDescription)"
        }
    }

    func receiveQueueItem(_ item: QueueItem) async {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let rawURL = URL(string: "\(urlString)/api/v1/clips/\(item.id)/raw") else { return }

        var request = URLRequest(url: rawURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        do {
            if item.type == "text" || item.type == "image" {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return }

                if httpResponse.statusCode == 200 {
                    if item.type == "text" {
                        if let text = String(data: data, encoding: .utf8) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            toastMessage = "Copied text to clipboard"
                        }
                    } else {
                        // image
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setData(data, forType: .png)
                        toastMessage = "Copied image to clipboard"
                    }
                    // Remove from local queue (server already deleted it)
                    queueItems.removeAll { $0.id == item.id }
                    dismissToastAfterDelay()
                } else if httpResponse.statusCode == 410 {
                    toastMessage = "Already consumed by another device"
                    queueItems.removeAll { $0.id == item.id }
                    dismissToastAfterDelay()
                } else {
                    toastMessage = "Failed to receive (status \(httpResponse.statusCode))"
                    dismissToastAfterDelay()
                }
            } else {
                // File — download to ~/Downloads/
                let delegate = DownloadProgressDelegate()
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

                let (tempURL, response) = try await session.download(for: request)
                session.invalidateAndCancel()

                guard let httpResponse = response as? HTTPURLResponse else { return }

                if httpResponse.statusCode == 200 {
                    let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Downloads")
                    let filename = item.filename ?? item.id
                    var destURL = downloadsURL.appendingPathComponent(filename)

                    // Avoid overwriting existing files
                    let fm = FileManager.default
                    if fm.fileExists(atPath: destURL.path) {
                        let base = destURL.deletingPathExtension().lastPathComponent
                        let ext = destURL.pathExtension
                        var counter = 1
                        repeat {
                            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                            destURL = downloadsURL.appendingPathComponent(newName)
                            counter += 1
                        } while fm.fileExists(atPath: destURL.path)
                    }

                    try fm.moveItem(at: tempURL, to: destURL)
                    toastMessage = "Saved \(destURL.lastPathComponent) to Downloads"
                    queueItems.removeAll { $0.id == item.id }
                    dismissToastAfterDelay()
                    NSWorkspace.shared.activateFileViewerSelecting([destURL])
                } else if httpResponse.statusCode == 410 {
                    toastMessage = "Already consumed by another device"
                    queueItems.removeAll { $0.id == item.id }
                    dismissToastAfterDelay()
                } else {
                    toastMessage = "Failed to receive (status \(httpResponse.statusCode))"
                    dismissToastAfterDelay()
                }
            }
        } catch {
            toastMessage = "Network error: \(error.localizedDescription)"
            dismissToastAfterDelay()
        }
    }

    private func dismissToastAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            toastMessage = nil
        }
    }

    // MARK: - Device List

    func fetchDevices() async {
        guard isConfigured else { return }

        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/api/v1/devices") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            var devices: [DeviceInfo] = []
            for json in jsonArray {
                guard let id = json["device_id"] as? String,
                      let name = json["name"] as? String,
                      let platform = json["platform"] as? String else { continue }
                // Exclude self
                if id == deviceID { continue }
                let lastSeenAtStr = json["last_seen_at"] as? String ?? ""
                let lastSeenAt = isoFormatter.date(from: lastSeenAtStr) ?? Date()
                devices.append(DeviceInfo(id: id, name: name, platform: platform, lastSeenAt: lastSeenAt))
            }
            availableDevices = devices
        } catch {
            // Best-effort — don't block
        }
    }

    // MARK: - SSE Auto-Receive

    func startSSE() {
        guard isConfigured, !deviceID.isEmpty else { return }
        // Don't start a second connection
        guard sseTask == nil else { return }
        sseRetryDelay = 1.0
        sseTask = Task { await sseLoop() }
    }

    func stopSSE() {
        sseTask?.cancel()
        sseTask = nil
    }

    private func sseLoop() async {
        while !Task.isCancelled {
            do {
                try await connectSSE()
            } catch is CancellationError {
                return
            } catch {
                // Reconnect with exponential backoff
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: UInt64(sseRetryDelay * 1_000_000_000))
                if Task.isCancelled { return }
                sseRetryDelay = min(sseRetryDelay * 2, sseMaxRetryDelay)
            }
        }
    }

    private func connectSSE() async throws {
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let url = URL(string: "\(urlString)/api/v1/devices/\(deviceID)/stream") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Connected successfully — reset backoff
        sseRetryDelay = 1.0

        var eventType = ""
        var dataBuffer = ""

        for try await line in bytes.lines {
            if Task.isCancelled { return }

            if line.isEmpty {
                // Empty line = end of event
                if eventType == "clip" && !dataBuffer.isEmpty {
                    await handleSSEClipEvent(dataBuffer)
                }
                eventType = ""
                dataBuffer = ""
            } else if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                dataBuffer = String(line.dropFirst(6))
            }
            // Ignore id:, comments (:), etc.
        }
    }

    private func handleSSEClipEvent(_ jsonString: String) async {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clipID = json["clip_id"] as? String,
              let clipType = json["type"] as? String else { return }

        let filename = json["filename"] as? String

        // Auto-receive the targeted clip
        let urlString = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard let rawURL = URL(string: "\(urlString)/api/v1/clips/\(clipID)/raw") else { return }

        var request = URLRequest(url: rawURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        do {
            if clipType == "text" {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
                if let text = String(data: responseData, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    toastMessage = "Received text from sender"
                    dismissToastAfterDelay()
                    AppDelegate.sendNotification(body: "Received text from sender")
                }
            } else if clipType == "image" {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(responseData, forType: .png)
                toastMessage = "Received image from sender"
                dismissToastAfterDelay()
                AppDelegate.sendNotification(body: "Received image from sender")
            } else {
                // File — download to ~/Downloads/
                let delegate = DownloadProgressDelegate()
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

                let (tempURL, response) = try await session.download(for: request)
                session.invalidateAndCancel()

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

                let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads")
                let destFilename = filename ?? clipID
                var destURL = downloadsURL.appendingPathComponent(destFilename)

                // Avoid overwriting existing files
                let fm = FileManager.default
                if fm.fileExists(atPath: destURL.path) {
                    let base = destURL.deletingPathExtension().lastPathComponent
                    let ext = destURL.pathExtension
                    var counter = 1
                    repeat {
                        let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                        destURL = downloadsURL.appendingPathComponent(newName)
                        counter += 1
                    } while fm.fileExists(atPath: destURL.path)
                }

                try fm.moveItem(at: tempURL, to: destURL)
                toastMessage = "Saved \(destURL.lastPathComponent) to Downloads"
                dismissToastAfterDelay()
                AppDelegate.sendNotification(body: "Saved \(destURL.lastPathComponent) to Downloads")
                NSWorkspace.shared.activateFileViewerSelecting([destURL])
            }

            // Remove from local queue if present
            queueItems.removeAll { $0.id == clipID }
        } catch {
            // Auto-receive failed silently — the item remains in the queue for manual receive
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Appends sender_device_id and target_device_id multipart fields to a body.
    private func appendDeviceFields(to body: inout Data, boundary: String) {
        if !deviceID.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"sender_device_id\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(deviceID)\r\n".data(using: .utf8)!)
        }
        if let targetID = targetDeviceID {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"target_device_id\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(targetID)\r\n".data(using: .utf8)!)
        }
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

                // Bundle.main.bundleIdentifier is nil for un-bundled SPM builds (`swift run`),
                // and UNUserNotificationCenter.current() throws NSInternalInconsistencyException in that case.
                if Bundle.main.bundleIdentifier != nil {
                    let content = UNMutableNotificationContent()
                    content.title = "CopyEverywhere"
                    content.body = "Copied to clipboard"
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                    try? await UNUserNotificationCenter.current().add(request)
                }

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

// MARK: - Download Progress Delegate

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let continuation: AsyncStream<(Int64, Int64)>.Continuation
    let progressStream: AsyncStream<(Int64, Int64)>

    override init() {
        var cont: AsyncStream<(Int64, Int64)>.Continuation!
        progressStream = AsyncStream { cont = $0 }
        continuation = cont
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        continuation.yield((totalBytesWritten, totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        continuation.finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish()
    }
}
