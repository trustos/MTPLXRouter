import Foundation
import Network

/// OpenAI-compatible reverse proxy. Routes by the request body's `model`,
/// lazy-loads/swaps the backing mtplx daemon, then relays bytes verbatim
/// (works identically for streaming SSE and plain JSON).
final class RouterServer {
    static let shared = RouterServer()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mtplx.router.listener")
    private(set) var isRunning = false
    private(set) var lastError: String?
    var onStateChange: ((Bool, String?) -> Void)?

    private var bindAttempt = 0

    func start() throws {
        stop()
        bindAttempt = 0
        try bindListener()
    }

    /// Bind the listener. On a quick restart (e.g. Save), the just-cancelled previous
    /// listener may not have released the port yet — `NWListener.cancel()` is async — so
    /// the bind hits a transient `EADDRINUSE`. Retry briefly before treating it as a real
    /// external conflict.
    private func bindListener() throws {
        let cfg = ConfigStore.shared.config
        guard let port = NWEndpoint.Port(rawValue: UInt16(cfg.router.port)) else {
            throw RouterError.badRequest("invalid router port")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let loopbackOnly = (cfg.router.host == "127.0.0.1" || cfg.router.host.lowercased() == "localhost")
        let l = try NWListener(using: params, on: port)
        let routerHost = cfg.router.host
        let routerPort = cfg.router.port
        l.newConnectionHandler = { conn in
            if loopbackOnly, !ClientSession.isLoopback(conn.endpoint) { conn.cancel(); return }
            ClientSession(conn: conn).begin()
        }
        l.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                self.bindAttempt = 0
                self.isRunning = true
                self.lastError = nil
                LogStore.shared.log("router listening on \(routerHost):\(routerPort)")
                self.onStateChange?(true, nil)
            case .failed(let e):
                if case let .posix(code) = e, code == .EADDRINUSE, self.bindAttempt < 12 {
                    self.bindAttempt += 1
                    let old = self.listener
                    self.listener = nil
                    old?.stateUpdateHandler = nil
                    old?.cancel()
                    self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        try? self?.bindListener()
                    }
                    return
                }
                self.isRunning = false
                let msg = RouterServer.friendly(e, port: routerPort)
                self.lastError = msg
                LogStore.shared.log("router listener failed: \(e)")
                self.onStateChange?(false, msg)
            case .cancelled:
                self.isRunning = false
                self.onStateChange?(false, self.lastError)
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    static func friendly(_ e: NWError, port: Int) -> String {
        if case let .posix(code) = e, code == .EADDRINUSE {
            return "Router port \(port) is already in use (another instance or service). Change the router port in Settings ▸ Router."
        }
        return "Router couldn’t start: \(e.localizedDescription)"
    }

    /// Where the router forwards each request: the Headroom compression proxy if
    /// `compressionProxyURL` is set, else mtplx directly on the backend port.
    static func backendTarget(_ cfg: AppConfig) -> (host: String, port: Int) {
        let s = cfg.compressionProxyURL.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty, let u = URLComponents(string: s), let h = u.host {
            return (h, u.port ?? 80)
        }
        return ("127.0.0.1", cfg.backendPort)
    }
}

/// One client connection: parse the request, route it, relay the response.
private final class ClientSession {
    let conn: NWConnection
    let q = DispatchQueue(label: "mtplx.router.client")

    private var buffer = Data()
    private var headParsed = false
    private var routed = false
    private var headerEnd = 0
    private var method = ""
    private var path = ""
    private var headers: [String: String] = [:]
    private var headerOrder: [(String, String)] = []
    private var contentLength = 0

    init(conn: NWConnection) { self.conn = conn }

    static func isLoopback(_ ep: NWEndpoint) -> Bool {
        if case let .hostPort(host, _) = ep {
            let h = "\(host)"
            return h.contains("127.0.0.1") || h.contains("::1") || h == "localhost" || h.hasPrefix("127.")
        }
        return true
    }

    func begin() {
        conn.stateUpdateHandler = { st in
            if case .failed = st { self.conn.cancel() }
        }
        conn.start(queue: q)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty { self.buffer.append(data) }
            if let error = error { LogStore.shared.log("client read error: \(error)"); self.conn.cancel(); return }
            if self.requestComplete() { self.route(); return }
            if isComplete { self.conn.cancel(); return }
            self.receive()
        }
    }

    private func requestComplete() -> Bool {
        parseHeadIfNeeded()
        guard headParsed else { return false }
        if method == "GET" || method == "HEAD" { return true }
        return (buffer.count - headerEnd) >= contentLength
    }

    private func parseHeadIfNeeded() {
        guard !headParsed else { return }
        guard let r = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        headParsed = true
        headerEnd = r.upperBound
        let head = String(decoding: buffer.subdata(in: buffer.startIndex..<r.lowerBound), as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let reqLine = lines.first ?? ""
        let parts = reqLine.split(separator: " ", maxSplits: 2)
        if parts.count >= 2 { method = String(parts[0]); path = String(parts[1]) }
        if !lines.isEmpty { lines.removeFirst() }
        for ln in lines {
            guard let idx = ln.firstIndex(of: ":") else { continue }
            let name = String(ln[..<idx]).trimmingCharacters(in: .whitespaces)
            let val = String(ln[ln.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = val
            headerOrder.append((name, val))
        }
        contentLength = Int(headers["content-length"] ?? "") ?? 0
    }

    // MARK: routing

    private func route() {
        guard !routed else { return }
        routed = true
        DaemonManager.shared.touch()

        if method == "GET", path.hasPrefix("/v1/models") { respondModels(); return }
        if path == "/healthz" || path == "/" { respondText(200, "ok\n"); return }
        if method != "POST" { fail(405, "method not allowed"); return }

        let cfg = ConfigStore.shared.config
        if !cfg.router.apiKey.isEmpty && !authOK(cfg.router.apiKey) {
            fail(401, "missing or invalid API key"); return
        }

        let body = buffer.subdata(in: headerEnd..<buffer.endIndex)
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let requested = obj["model"] as? String else {
            fail(400, "missing 'model' in request body"); return
        }
        guard let entry = ConfigStore.shared.modelEntry(forRequested: requested) else {
            fail(404, "unknown model '\(requested)'"); return
        }

        var newObj = obj
        newObj["model"] = entry.id   // canonicalize alias → served id
        let newBody = (try? JSONSerialization.data(withJSONObject: newObj)) ?? body
        let reqBytes = buildBackendRequest(path: path, body: newBody, cfg: cfg)
        let streaming = (obj["stream"] as? Bool) == true
        LogStore.shared.log("\(method) \(path)  model=\(requested) → \(entry.id) (\(streaming ? "stream" : "json"))")

        DispatchQueue.global(qos: .userInitiated).async {
            do { try DaemonManager.shared.ensure(modelId: entry.id) }
            catch { self.fail(503, "model load failed: \(error)"); return }
            DaemonManager.shared.touch()
            self.forward(requestBytes: reqBytes)
        }
    }

    private func authOK(_ key: String) -> Bool {
        if let a = headers["authorization"], a == "Bearer \(key)" { return true }
        if let x = headers["x-api-key"], x == key { return true }
        return false
    }

    private func buildBackendRequest(path: String, body: Data, cfg: AppConfig) -> Data {
        var h = "POST \(path) HTTP/1.1\r\n"
        h += "Host: 127.0.0.1:\(cfg.backendPort)\r\n"
        let skip: Set<String> = ["host", "content-length", "connection", "accept-encoding",
                                 "authorization", "transfer-encoding", "x-api-key"]
        var sawCT = false
        for (name, val) in headerOrder {
            let low = name.lowercased()
            if skip.contains(low) { continue }
            if low == "content-type" { sawCT = true }
            h += "\(name): \(val)\r\n"
        }
        if !sawCT { h += "Content-Type: application/json\r\n" }
        h += "Content-Length: \(body.count)\r\n"
        h += "Connection: close\r\n\r\n"
        var out = Data(h.utf8); out.append(body)
        return out
    }

    // MARK: forward / relay

    private func forward(requestBytes: Data) {
        let cfg = ConfigStore.shared.config
        // Forward to the Headroom compression proxy if configured, else straight to mtplx.
        let target = RouterServer.backendTarget(cfg)
        guard let port = NWEndpoint.Port(rawValue: UInt16(target.port)) else {
            fail(502, "bad backend port"); return
        }
        let backend = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        backend.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready:
                backend.send(content: requestBytes, completion: .contentProcessed { err in
                    if let err = err { self.fail(502, "backend send: \(err)"); backend.cancel(); return }
                    self.pump(from: backend)
                })
            case .failed(let e):
                self.fail(503, "backend connect: \(e)")
            default: break
            }
        }
        backend.start(queue: q)
    }

    private func pump(from backend: NWConnection) {
        backend.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.conn.send(content: data, completion: .contentProcessed { _ in })
            }
            if let error = error { LogStore.shared.log("backend read error: \(error)"); backend.cancel(); self.conn.cancel(); return }
            if isComplete {
                DaemonManager.shared.touch()
                self.conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in self.conn.cancel() })
                backend.cancel(); return
            }
            self.pump(from: backend)
        }
    }

    // MARK: local responses

    private func respondModels() {
        let cfg = ConfigStore.shared.config
        let now = Int(Date().timeIntervalSince1970)
        var data: [[String: Any]] = []
        var seen = Set<String>()
        for m in cfg.models where m.enabled {
            for ident in [m.id, m.alias] where !ident.isEmpty && !seen.contains(ident) {
                seen.insert(ident)
                data.append(["id": ident, "object": "model", "created": now, "owned_by": "mtplx", "root": m.id])
            }
        }
        respondJSON(200, ["object": "list", "data": data])
    }

    private func respondJSON(_ status: Int, _ obj: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        writeResponse(status: status, contentType: "application/json", body: body)
    }
    private func respondText(_ status: Int, _ text: String) {
        writeResponse(status: status, contentType: "text/plain", body: Data(text.utf8))
    }
    private func fail(_ status: Int, _ msg: String) {
        LogStore.shared.log("HTTP \(status): \(msg)")
        respondJSON(status, ["error": ["message": msg, "type": "router_error"]])
    }
    private func writeResponse(status: Int, contentType: String, body: Data) {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, isComplete: true, completion: .contentProcessed { _ in self.conn.cancel() })
    }
    private func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"; case 400: return "Bad Request"; case 401: return "Unauthorized"
        case 404: return "Not Found"; case 405: return "Method Not Allowed"
        case 502: return "Bad Gateway"; case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
