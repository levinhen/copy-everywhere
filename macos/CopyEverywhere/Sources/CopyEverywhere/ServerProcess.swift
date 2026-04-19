import Foundation

/// Manages the Go server binary as a child process.
@MainActor
final class ServerProcess: ObservableObject {
    @Published var isRunning = false
    @Published var logLines: [String] = []

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Maximum number of log lines retained in memory.
    private let maxLogLines = 500

    /// Path to the Go server binary. Defaults to a sibling `copyeverywhere-server`
    /// next to the running Swift executable, but can be overridden.
    var binaryPath: String = {
        defaultSiblingBinaryPath()
    }()

    /// Server configuration — environment variables are derived from this.
    var config: ServerConfig?

    /// Environment variables forwarded to the Go server subprocess.
    var environment: [String: String] {
        config?.environment ?? [:]
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        stageBundledBinaryIfNeeded()

        let binaryURL = URL(fileURLWithPath: binaryPath)
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            appendLog("[host] Failed to start server: binary not found or not executable at \(binaryURL.path)")
            return
        }

        let proc = Process()
        proc.executableURL = binaryURL

        // Merge current environment with user overrides
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        proc.environment = env

        // Capture stdout
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        stdoutPipe = outPipe

        // Capture stderr
        let errPipe = Pipe()
        proc.standardError = errPipe
        stderrPipe = errPipe

        // Handle unexpected termination
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTermination()
            }
        }

        do {
            try proc.run()
            process = proc
            isRunning = true
            appendLog("[host] Server started (PID \(proc.processIdentifier)) from \(binaryURL.path)")
            readPipe(outPipe, prefix: "")
            readPipe(errPipe, prefix: "")
        } catch {
            appendLog("[host] Failed to start server from \(binaryURL.path): \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        appendLog("[host] Sending SIGTERM…")
        proc.terminate() // sends SIGTERM
    }

    func restart() {
        stop()
        // Wait for the process to actually exit before starting again,
        // so the old mDNS registration is fully deregistered first.
        Task {
            for _ in 0..<50 {
                if !isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
            start()
        }
    }

    // MARK: - Pipe reading

    private func readPipe(_ pipe: Pipe, prefix: String) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            if let str = String(data: data, encoding: .utf8) {
                let lines = str.components(separatedBy: .newlines).filter { !$0.isEmpty }
                Task { @MainActor [weak self] in
                    for line in lines {
                        self?.appendLog(prefix + line)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    private func handleTermination() {
        let code = process?.terminationStatus ?? -1
        isRunning = false
        process = nil
        appendLog("[host] Server exited (code \(code))")
    }

    deinit {
        // Best-effort cleanup — terminate if still running
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }

    private func stageBundledBinaryIfNeeded() {
        let fileManager = FileManager.default
        let targetURL = URL(fileURLWithPath: binaryPath)

        guard let sourceURL = Self.findRepoBinaryURL(),
              fileManager.isExecutableFile(atPath: sourceURL.path) else {
            return
        }

        let shouldCopy: Bool
        if !fileManager.fileExists(atPath: targetURL.path) {
            shouldCopy = true
        } else {
            let sourceDate = (try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let targetDate = (try? targetURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            shouldCopy = sourceDate > targetDate
        }

        guard shouldCopy else { return }

        do {
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetURL.path)
            appendLog("[host] Staged server binary to \(targetURL.path)")
        } catch {
            appendLog("[host] Failed to stage server binary from \(sourceURL.path) to \(targetURL.path): \(error.localizedDescription)")
        }
    }

    private static func defaultSiblingBinaryPath() -> String {
        let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        return execURL.deletingLastPathComponent().appendingPathComponent("copyeverywhere-server").path
    }

    private static func findRepoBinaryURL() -> URL? {
        let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let fileManager = FileManager.default
        let siblingBinary = execURL.deletingLastPathComponent().appendingPathComponent("copyeverywhere-server")
        if fileManager.isExecutableFile(atPath: siblingBinary.path) {
            return siblingBinary
        }

        // SwiftPM debug runs launch from `macos/CopyEverywhere/.build/.../CopyEverywhere`.
        // In that setup the Go server binary usually lives in the repo root under `server/`.
        let devRepoBinary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/CopyEverywhere
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // CopyEverywhere package root
            .deletingLastPathComponent() // macos
            .appendingPathComponent("server/copyeverywhere-server")
        if fileManager.isExecutableFile(atPath: devRepoBinary.path) {
            return devRepoBinary
        }

        return nil
    }
}
