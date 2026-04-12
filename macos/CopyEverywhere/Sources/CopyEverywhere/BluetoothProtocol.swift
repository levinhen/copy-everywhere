import Foundation
import IOBluetooth

// MARK: - Protocol constants

/// App-layer handshake exchanged immediately after RFCOMM connection.
let kBluetoothHandshake: [String: String] = ["app": "CopyEverywhere", "version": "3.0"]

/// Timeout for the handshake exchange (seconds).
private let kHandshakeTimeout: TimeInterval = 5.0

/// Newline delimiter separating JSON headers from content on the wire.
private let kDelimiter = Data([0x0A]) // "\n"

// MARK: - Transfer header

/// JSON header sent before content bytes.
struct BluetoothTransferHeader: Codable {
    enum ContentType: String, Codable {
        case text
        case file
    }

    let type: ContentType
    let filename: String
    let size: Int
}

// MARK: - Received transfer

/// A fully received transfer (header + content bytes).
struct BluetoothTransferPayload {
    let header: BluetoothTransferHeader
    let data: Data
}

// MARK: - Session delegate

@MainActor
protocol BluetoothSessionDelegate: AnyObject {
    /// Handshake completed successfully; session is ready for transfers.
    func sessionDidComplete(handshake session: BluetoothSession)
    /// Handshake failed or timed out.
    func session(_ session: BluetoothSession, handshakeFailedWithError error: Error)
    /// A complete transfer was received from the remote peer.
    func session(_ session: BluetoothSession, didReceive payload: BluetoothTransferPayload)
    /// Receive progress updated (0.0 to 1.0).
    func session(_ session: BluetoothSession, receiveProgress progress: Double, header: BluetoothTransferHeader)
    /// An error occurred during receive.
    func session(_ session: BluetoothSession, didFailReceivingWithError error: Error)
}

// MARK: - Session errors

enum BluetoothSessionError: LocalizedError {
    case handshakeTimeout
    case handshakeMismatch(String)
    case invalidHeader
    case writeFailed(IOReturn)
    case channelClosed
    case sizeMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .handshakeTimeout: return "Bluetooth handshake timed out"
        case .handshakeMismatch(let detail): return "Bluetooth handshake mismatch: \(detail)"
        case .invalidHeader: return "Invalid transfer header"
        case .writeFailed(let code): return "RFCOMM write failed with code: \(code)"
        case .channelClosed: return "RFCOMM channel is closed"
        case .sizeMismatch(let expected, let actual): return "Size mismatch: expected \(expected) bytes, received \(actual) bytes"
        }
    }
}

// MARK: - BluetoothSession

/// Manages the app-layer protocol on top of a connected RFCOMM channel.
///
/// Lifecycle:
/// 1. Init with connected channel → automatically sends handshake
/// 2. Delegate receives `sessionDidComplete(handshake:)` on success
/// 3. Use `sendText(_:)` / `sendFile(url:)` to push content
/// 4. Incoming transfers arrive via `session(_:didReceive:)`
@MainActor
final class BluetoothSession: NSObject, ObservableObject {

    let channel: IOBluetoothRFCOMMChannel
    weak var delegate: BluetoothSessionDelegate?

    @Published var isHandshakeComplete = false

    // Send progress stream
    private var sendProgressContinuation: AsyncStream<Double>.Continuation?
    private(set) var sendProgressStream: AsyncStream<Double>?

    // Receive buffer
    private var receiveBuffer = Data()
    private var pendingHeader: BluetoothTransferHeader?
    private var bytesRemaining: Int = 0

    // Handshake state
    private var handshakeTimer: DispatchWorkItem?
    private var handshakeSent = false
    private var handshakeReceived = false

    init(channel: IOBluetoothRFCOMMChannel) {
        self.channel = channel
        super.init()
        // Set ourselves as the channel delegate to receive data
        channel.setDelegate(self)
        beginHandshake()
    }

    // MARK: - Handshake

    private func beginHandshake() {
        // Start timeout
        let timer = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isHandshakeComplete else { return }
                self.delegate?.session(self, handshakeFailedWithError: BluetoothSessionError.handshakeTimeout)
            }
        }
        handshakeTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + kHandshakeTimeout, execute: timer)

        // Send our handshake
        sendJSON(kBluetoothHandshake) { [weak self] error in
            guard let self else { return }
            if let error {
                self.handshakeTimer?.cancel()
                self.delegate?.session(self, handshakeFailedWithError: error)
                return
            }
            self.handshakeSent = true
            self.checkHandshakeComplete()
        }
    }

    private func checkHandshakeComplete() {
        guard handshakeSent, handshakeReceived, !isHandshakeComplete else { return }
        isHandshakeComplete = true
        handshakeTimer?.cancel()
        handshakeTimer = nil
        delegate?.sessionDidComplete(handshake: self)
    }

    // MARK: - Send

    /// Send a text string to the remote peer. Returns an AsyncStream<Double> for progress tracking.
    func sendText(_ text: String, completion: (@MainActor (Error?) -> Void)? = nil) -> AsyncStream<Double> {
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        sendProgressContinuation = continuation
        sendProgressStream = stream

        guard isHandshakeComplete else {
            completion?(BluetoothSessionError.channelClosed)
            continuation.finish()
            return stream
        }
        guard let contentData = text.data(using: .utf8) else {
            completion?(BluetoothSessionError.writeFailed(kIOReturnBadArgument))
            continuation.finish()
            return stream
        }
        let header = BluetoothTransferHeader(type: .text, filename: "clipboard.txt", size: contentData.count)
        sendTransfer(header: header, content: contentData) { [weak self] error in
            self?.sendProgressContinuation?.yield(1.0)
            self?.sendProgressContinuation?.finish()
            completion?(error)
        }
        return stream
    }

    /// Send a file to the remote peer. Reads in chunks to avoid OOM on large files.
    /// Returns an AsyncStream<Double> for progress tracking.
    func sendFile(url: URL, completion: (@MainActor (Error?) -> Void)? = nil) -> AsyncStream<Double> {
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        sendProgressContinuation = continuation
        sendProgressStream = stream

        guard isHandshakeComplete else {
            completion?(BluetoothSessionError.channelClosed)
            continuation.finish()
            return stream
        }
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            completion?(BluetoothSessionError.writeFailed(kIOReturnBadArgument))
            continuation.finish()
            return stream
        }

        let fileSize: Int
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = (attrs[.size] as? Int) ?? 0
        } catch {
            completion?(error)
            continuation.finish()
            try? fileHandle.close()
            return stream
        }

        let header = BluetoothTransferHeader(type: .file, filename: url.lastPathComponent, size: fileSize)

        // Send header
        guard let headerData = try? JSONEncoder().encode(header) else {
            completion?(BluetoothSessionError.invalidHeader)
            continuation.finish()
            try? fileHandle.close()
            return stream
        }
        var payload = headerData
        payload.append(kDelimiter)

        writeData(payload) { [weak self] error in
            guard let self else { return }
            if let error {
                completion?(error)
                self.sendProgressContinuation?.finish()
                try? fileHandle.close()
                return
            }
            // Stream file content in chunks
            self.streamFileContent(fileHandle: fileHandle, totalSize: fileSize, remaining: fileSize, completion: { [weak self] error in
                try? fileHandle.close()
                self?.sendProgressContinuation?.yield(1.0)
                self?.sendProgressContinuation?.finish()
                completion?(error)
            })
        }
        return stream
    }

    private func streamFileContent(fileHandle: FileHandle, totalSize: Int, remaining: Int, completion: (@MainActor (Error?) -> Void)?) {
        let chunkSize = 16 * 1024 // 16 KB chunks over RFCOMM
        guard remaining > 0 else {
            completion?(nil)
            return
        }
        let readSize = min(chunkSize, remaining)
        guard let chunk = try? fileHandle.read(upToCount: readSize), !chunk.isEmpty else {
            completion?(nil)
            return
        }
        let newRemaining = remaining - chunk.count
        writeData(chunk) { [weak self] error in
            guard let self else { return }
            if let error {
                completion?(error)
                return
            }
            // Report progress
            if totalSize > 0 {
                let progress = Double(totalSize - newRemaining) / Double(totalSize)
                self.sendProgressContinuation?.yield(progress)
            }
            self.streamFileContent(fileHandle: fileHandle, totalSize: totalSize, remaining: newRemaining, completion: completion)
        }
    }

    private func sendTransfer(header: BluetoothTransferHeader, content: Data, completion: (@MainActor (Error?) -> Void)?) {
        guard let headerData = try? JSONEncoder().encode(header) else {
            completion?(BluetoothSessionError.invalidHeader)
            return
        }
        var payload = headerData
        payload.append(kDelimiter)
        payload.append(content)

        writeData(payload, completion: completion)
    }

    // MARK: - Low-level write

    private func sendJSON<T: Encodable>(_ value: T, completion: (@MainActor (Error?) -> Void)?) {
        guard let data = try? JSONEncoder().encode(value) else {
            completion?(BluetoothSessionError.invalidHeader)
            return
        }
        var payload = data
        payload.append(kDelimiter)
        writeData(payload, completion: completion)
    }

    private func writeData(_ data: Data, completion: (@MainActor (Error?) -> Void)?) {
        let mutableData = NSMutableData(data: data)
        let status = channel.writeAsync(mutableData.mutableBytes, length: UInt16(data.count), refcon: nil)
        if status != kIOReturnSuccess {
            completion?(BluetoothSessionError.writeFailed(status))
        } else {
            completion?(nil)
        }
    }

    // MARK: - Receive processing

    private func processReceivedData() {
        // Phase 1: Handshake
        if !handshakeReceived {
            processHandshakeData()
            return
        }

        // Phase 2: Transfer header + content
        processTransferData()
    }

    private func processHandshakeData() {
        guard let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) else {
            return // Wait for complete handshake line
        }
        let lineData = receiveBuffer[receiveBuffer.startIndex..<newlineIndex]
        receiveBuffer = Data(receiveBuffer[(newlineIndex + 1)...])

        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: String],
              json["app"] == "CopyEverywhere" else {
            delegate?.session(self, handshakeFailedWithError:
                BluetoothSessionError.handshakeMismatch("invalid or missing app field"))
            return
        }

        handshakeReceived = true
        checkHandshakeComplete()

        // Process any remaining data as transfer data
        if !receiveBuffer.isEmpty {
            processTransferData()
        }
    }

    private func processTransferData() {
        // If we don't have a pending header yet, try to parse one
        if pendingHeader == nil {
            guard let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) else {
                return // Wait for complete header line
            }
            let headerData = receiveBuffer[receiveBuffer.startIndex..<newlineIndex]
            receiveBuffer = Data(receiveBuffer[(newlineIndex + 1)...])

            guard let header = try? JSONDecoder().decode(BluetoothTransferHeader.self, from: headerData) else {
                delegate?.session(self, didFailReceivingWithError: BluetoothSessionError.invalidHeader)
                return
            }
            pendingHeader = header
            bytesRemaining = header.size
        }

        // Collect content bytes
        guard let header = pendingHeader else { return }

        // Report receive progress
        let totalSize = header.size
        if totalSize > 0 {
            let received = totalSize - bytesRemaining + min(receiveBuffer.count, bytesRemaining)
            let progress = min(Double(received) / Double(totalSize), 1.0)
            delegate?.session(self, receiveProgress: progress, header: header)
        }

        if receiveBuffer.count >= bytesRemaining {
            // We have all the content
            let contentData = Data(receiveBuffer[receiveBuffer.startIndex..<(receiveBuffer.startIndex + bytesRemaining)])
            receiveBuffer = Data(receiveBuffer[(receiveBuffer.startIndex + bytesRemaining)...])
            pendingHeader = nil
            bytesRemaining = 0

            // Verify total bytes match header-declared size
            guard contentData.count == header.size else {
                delegate?.session(self, didFailReceivingWithError: BluetoothSessionError.sizeMismatch(expected: header.size, actual: contentData.count))
                return
            }

            let payload = BluetoothTransferPayload(header: header, data: contentData)
            delegate?.session(self, didReceive: payload)

            // Process any remaining data (next transfer)
            if !receiveBuffer.isEmpty {
                processTransferData()
            }
        }
        // Otherwise, wait for more data
    }

    // MARK: - Cleanup

    func close() {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        channel.setDelegate(nil)
        _ = channel.close()
    }

    deinit {
        handshakeTimer?.cancel()
    }
}

// MARK: - IOBluetoothRFCOMMChannelDelegate

extension BluetoothSession: IOBluetoothRFCOMMChannelDelegate {

    /// Called when data arrives on the RFCOMM channel.
    nonisolated func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard let dataPointer else { return }
        let data = Data(bytes: dataPointer, count: dataLength)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.receiveBuffer.append(data)
            self.processReceivedData()
        }
    }

    /// Called when the channel is closed by the remote peer.
    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.isHandshakeComplete {
                self.delegate?.session(self, handshakeFailedWithError: BluetoothSessionError.channelClosed)
            }
        }
    }
}
