import Foundation

enum DaemonState: Equatable {
    case stopped
    case starting(String)   // modelId
    case ready(String)      // modelId
    case failed(String)     // message

    var short: String {
        switch self {
        case .stopped:        return "idle"
        case .starting(let m): return "loading \(m)…"
        case .ready(let m):    return m
        case .failed:         return "error"
        }
    }
}

/// Owns exactly one backend mtplx daemon on a reused port (strict swap).
final class DaemonManager {
    static let shared = DaemonManager()
    private let lock = NSRecursiveLock()

    private var process: Process?
    private var ownsProcess = false
    private(set) var currentModelId: String?
    private(set) var lastActivity = Date()
    private(set) var state: DaemonState = .stopped {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((DaemonState) -> Void)?
    private var cfg: AppConfig { ConfigStore.shared.config }

    var loadedModelId: String? {
        lock.lock(); defer { lock.unlock() }
        if case .ready(let m) = state { return m }
        return nil
    }

    func touch() { lock.lock(); lastActivity = Date(); lock.unlock() }
    func idleSeconds() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastActivity) }

    func currentRSS() -> Int64? {
        guard let pid = pidListening(onPort: cfg.backendPort) else { return nil }
        return rssBytes(pid: pid)
    }

    /// Ensure a healthy daemon serving `modelId`. Blocks until ready; throws on failure.
    func ensure(modelId: String) throws {
        lock.lock(); defer { lock.unlock() }
        if currentModelId == modelId, isHealthy() {
            if case .ready = state {} else { state = .ready(modelId) }
            return
        }
        guard let entry = cfg.models.first(where: { $0.id == modelId }) else {
            throw RouterError.unknownModel(modelId)
        }
        guard FileManager.default.isExecutableFile(atPath: cfg.mtplxBinary) else {
            state = .failed("mtplx not found"); throw RouterError.mtplxMissing(cfg.mtplxBinary)
        }
        guard FileManager.default.fileExists(atPath: entry.path) else {
            state = .failed("model folder missing"); throw RouterError.modelPathMissing(entry.path)
        }
        // If we don't already own a daemon but the port is busy, it's a foreign
        // process (or our orphan). Refuse rather than clobber it.
        if process == nil, currentModelId == nil, let pid = pidListening(onPort: cfg.backendPort) {
            state = .failed("backend port \(cfg.backendPort) busy")
            throw RouterError.backendPortBusy(cfg.backendPort, pid)
        }
        stopLocked(port: cfg.backendPort)
        state = .starting(modelId)
        LogStore.shared.log("swap → loading \(modelId)")
        try launch(entry: entry)
        try waitHealthy(timeout: TimeInterval(cfg.healthTimeoutSeconds))
        currentModelId = modelId
        lastActivity = Date()
        state = .ready(modelId)
        LogStore.shared.log("ready · \(modelId) (\(currentRSS().map(humanBytes) ?? "?"))")
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked(port: cfg.backendPort)
        state = .stopped
    }

    /// The backend port changed in config (Settings Save or an external `ccstack` edit).
    /// The live `cfg` already holds the NEW port, so an ordinary swap would tear down the
    /// new (empty) port and orphan the daemon still running on `oldPort` — especially since
    /// `quickstart` daemonizes, so we no longer own its child handle. Stop the OLD port
    /// explicitly here, then transparently re-warm whatever was loaded on the new port.
    func backendPortChanged(oldPort: Int) {
        lock.lock()
        let newPort = cfg.backendPort
        guard oldPort != newPort else { lock.unlock(); return }
        let reloadId = currentModelId
        let wasReady: Bool = { if case .ready = state { return true } else { return false } }()
        LogStore.shared.log("backend port \(oldPort) → \(newPort): stopping daemon on :\(oldPort)")
        stopLocked(port: oldPort)
        state = .stopped
        lock.unlock()
        // Re-warm outside the lock — ensure() takes the lock itself. If the new port is
        // foreign-held, ensure() throws backendPortBusy and Diagnostics surfaces it.
        if wasReady, let id = reloadId {
            DispatchQueue.global(qos: .userInitiated).async {
                try? DaemonManager.shared.ensure(modelId: id)
            }
        }
    }

    /// Force-stop whatever holds the backend port (recovery for orphans / foreign holders).
    func forceFreeBackendPort() {
        lock.lock(); defer { lock.unlock() }
        let port = cfg.backendPort
        if FileManager.default.isExecutableFile(atPath: cfg.mtplxBinary) {
            runTool(cfg.mtplxBinary, ["stop", "--port", String(port), "--grace-seconds", "5"])
        }
        if let pid = pidListening(onPort: port) { kill(pid, SIGKILL) }
        process = nil; ownsProcess = false; currentModelId = nil
        state = .stopped
        LogStore.shared.log("force-freed backend port \(port)")
    }

    // MARK: - internals

    private func launch(entry: ModelEntry) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.mtplxBinary)
        p.arguments = ["quickstart", "--model", entry.path, "--host", "127.0.0.1",
                       "--port", String(cfg.backendPort), "--model-id", entry.id, "--yes"]
        if let fh = try? FileHandle(forWritingTo: LogStore.shared.daemonLogURL) {
            fh.seekToEndOfFile()
            let banner = "\n===== \(LogStore.ts())  quickstart \(entry.id) =====\n"
            fh.write(banner.data(using: .utf8)!)
            p.standardOutput = fh
            p.standardError = fh
        }
        try p.run()
        process = p
        ownsProcess = true
    }

    private func waitHealthy(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isHealthy() {
                // quickstart may have daemonized: if our child already exited but the
                // port is healthy, switch to port-based liveness.
                if let p = process, !p.isRunning { ownsProcess = false }
                return
            }
            if ownsProcess, let p = process, !p.isRunning {
                let why = tailDaemonLog()
                state = .failed(why)
                throw RouterError.daemonExited(why)
            }
            usleep(400_000)
        }
        state = .failed("health timeout")
        throw RouterError.healthTimeout
    }

    private func isHealthy() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(cfg.backendPort)/v1/models") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let h = resp as? HTTPURLResponse, (200..<500).contains(h.statusCode) { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 4)
        return ok
    }

    private func stopLocked(port: Int) {
        let listening = pidListening(onPort: port)
        if process != nil || currentModelId != nil || listening != nil {
            LogStore.shared.log("stopping daemon on :\(port)")
        }
        // 1) clean stop via mtplx (SIGTERM → SIGKILL after grace)
        if listening != nil {
            runTool(cfg.mtplxBinary, ["stop", "--port", String(port), "--grace-seconds", "8"])
        }
        // 2) terminate our own child if we still own it
        if let p = process, p.isRunning {
            p.terminate()
            let dl = Date().addingTimeInterval(8)
            while p.isRunning && Date() < dl { usleep(100_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        // 3) last resort: kill whatever still holds the port
        if let pid = pidListening(onPort: port) { kill(pid, SIGKILL) }
        process = nil
        ownsProcess = false
        currentModelId = nil
    }

    @discardableResult
    private func runTool(_ bin: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    private func tailDaemonLog(_ lines: Int = 10) -> String {
        guard let data = try? Data(contentsOf: LogStore.shared.daemonLogURL),
              let s = String(data: data, encoding: .utf8) else { return "see daemon.log" }
        let arr = s.split(separator: "\n").map(String.init)
        let tail = arr.suffix(lines).joined(separator: " | ")
        return tail.isEmpty ? "see daemon.log" : String(tail.suffix(220))
    }
}
