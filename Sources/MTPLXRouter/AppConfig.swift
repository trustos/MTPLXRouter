import Foundation

extension Notification.Name {
    static let configChanged = Notification.Name("mtplx.router.configChanged")
    static let mtplxWebToolsSetup = Notification.Name("mtplx.router.webToolsSetup")
    /// The backend (mtplx) port changed. userInfo["old"] = previous port, so the
    /// daemon can be torn down on the OLD port before it's adopted (the live config
    /// already holds the new one). Fired by both Save and the external hot-reload.
    static let backendPortChanged = Notification.Name("mtplx.router.backendPortChanged")
}

struct ModelEntry: Codable, Identifiable, Hashable {
    var id: String          // served OpenAI model id (what clients request)
    var alias: String       // friendly alias, also routable (e.g. "planner")
    var displayName: String // shown in menus
    var path: String        // absolute model directory
    var enabled: Bool

    init(id: String, alias: String, displayName: String, path: String, enabled: Bool = true) {
        self.id = id; self.alias = alias; self.displayName = displayName
        self.path = path; self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, alias, displayName, path, enabled }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id          = try c.decode(String.self, forKey: .id)
        alias       = (try? c.decodeIfPresent(String.self, forKey: .alias)) ?? ""
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? id
        path        = try c.decode(String.self, forKey: .path)
        enabled     = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }
}

struct RouterConfig: Codable {
    var host: String = "127.0.0.1"
    var port: Int = 11435
    var apiKey: String = ""   // empty = no auth required

    init() {}
    enum CodingKeys: String, CodingKey { case host, port, apiKey }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        host   = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? "127.0.0.1"
        port   = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? 11435
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? ""
    }
}

struct StartupConfig: Codable {
    var launchAtLogin: Bool = false
    var startRouterOnLaunch: Bool = true
    var preloadModelId: String? = nil   // model to warm on launch; nil = none

    init() {}
    enum CodingKeys: String, CodingKey { case launchAtLogin, startRouterOnLaunch, preloadModelId }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        launchAtLogin       = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? false
        startRouterOnLaunch = (try? c.decodeIfPresent(Bool.self, forKey: .startRouterOnLaunch)) ?? true
        preloadModelId      = try? c.decodeIfPresent(String.self, forKey: .preloadModelId)
    }
}

/// Local web tools (private search + fetch) exposed to OpenCode as a stdio MCP
/// the agent spawns on demand. See WebToolsManager.
struct WebToolsConfig: Codable {
    var enabled: Bool = false
    /// Python used to build the web-tools venv. Defaults to Homebrew python@3.13
    /// (crawl4ai/Playwright don't support the 3.14 that's the system default).
    var pythonPath: String = "/opt/homebrew/opt/python@3.13/bin/python3.13"
    var maxResults: Int = 5

    init() {}
    enum CodingKeys: String, CodingKey { case enabled, pythonPath, maxResults }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled    = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        pythonPath = (try? c.decodeIfPresent(String.self, forKey: .pythonPath))
            ?? "/opt/homebrew/opt/python@3.13/bin/python3.13"
        maxResults = (try? c.decodeIfPresent(Int.self, forKey: .maxResults)) ?? 5
    }
}

struct AppConfig: Codable {
    var router: RouterConfig = RouterConfig()
    var backendPort: Int = 8011                 // single reused backend port (strict swap)
    var compressionProxyURL: String = ""        // optional Headroom proxy (router → here → mtplx); "" = direct
    var mtplxBinary: String = expandTilde("~/.mtplx/bin/mtplx")
    var modelsDir: String = expandTilde("~/.mtplx/models")
    var startup: StartupConfig = StartupConfig()
    var models: [ModelEntry] = AppConfig.defaultModels
    var healthTimeoutSeconds: Int = 180         // max wait for a daemon to become healthy
    var idleEvictMinutes: Int = 0               // 0 = never evict on idle
    var webTools: WebToolsConfig = WebToolsConfig()   // local search/fetch MCP for OpenCode

    init() {}
    enum CodingKeys: String, CodingKey {
        case router, backendPort, compressionProxyURL, mtplxBinary, modelsDir, startup, models, healthTimeoutSeconds, idleEvictMinutes, webTools
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        router              = (try? c.decodeIfPresent(RouterConfig.self, forKey: .router)) ?? RouterConfig()
        backendPort         = (try? c.decodeIfPresent(Int.self, forKey: .backendPort)) ?? 8011
        compressionProxyURL = (try? c.decodeIfPresent(String.self, forKey: .compressionProxyURL)) ?? ""
        mtplxBinary         = (try? c.decodeIfPresent(String.self, forKey: .mtplxBinary)) ?? expandTilde("~/.mtplx/bin/mtplx")
        modelsDir           = (try? c.decodeIfPresent(String.self, forKey: .modelsDir)) ?? expandTilde("~/.mtplx/models")
        startup             = (try? c.decodeIfPresent(StartupConfig.self, forKey: .startup)) ?? StartupConfig()
        // Absent key → seed defaults (first run / old config). An explicit empty
        // list is honored (Diagnostics will flag "No models configured").
        models              = (try? c.decodeIfPresent([ModelEntry].self, forKey: .models)) ?? AppConfig.defaultModels
        healthTimeoutSeconds = (try? c.decodeIfPresent(Int.self, forKey: .healthTimeoutSeconds)) ?? 180
        idleEvictMinutes     = (try? c.decodeIfPresent(Int.self, forKey: .idleEvictMinutes)) ?? 0
        webTools             = (try? c.decodeIfPresent(WebToolsConfig.self, forKey: .webTools)) ?? WebToolsConfig()
    }

    static var defaultModels: [ModelEntry] {
        [
            ModelEntry(id: "mtplx-qwen36-27b-optimized-quality", alias: "planner",
                       displayName: "Qwen3.6 27B · planner",
                       path: expandTilde("~/.mtplx/models/Youssofal--Qwen3.6-27B-MTPLX-Optimized-Quality")),
            ModelEntry(id: "mtplx-qwen36-35b-a3b-optimized-speed", alias: "builder",
                       displayName: "Qwen3.6 35B-A3B · builder",
                       path: expandTilde("~/.mtplx/models/Qwen-Qwen3.6-35B-A3B-MTPLX")),
        ]
    }
}

final class ConfigStore {
    static let shared = ConfigStore()
    private(set) var config: AppConfig
    let url: URL
    private var lastMtime: Date = .distantPast

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MTPLX Router", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = cfg
        } else {
            // Fresh install: lazy-load on first request (~7s) rather than pulling a
            // model at every login. Opt into preload in Settings if you prefer.
            config = AppConfig()
            ConfigStore.persist(config, to: url)
        }
        lastMtime = fileMtime() ?? .distantPast
    }

    func save(_ cfg: AppConfig) {
        let oldBackendPort = config.backendPort
        config = cfg
        ConfigStore.persist(cfg, to: url)
        lastMtime = fileMtime() ?? lastMtime
        NotificationCenter.default.post(name: .configChanged, object: nil)
        if oldBackendPort != cfg.backendPort {
            NotificationCenter.default.post(name: .backendPortChanged, object: nil,
                                            userInfo: ["old": oldBackendPort])
        }
    }

    private func fileMtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Re-read config.json if it changed on disk since we last loaded/saved it (e.g. `ccstack`
    /// writing `compressionProxyURL`). Stat-by-path so it survives atomic temp+rename replaces.
    /// `forward()` reads the config fresh per request, so a reloaded compressionProxyURL/backend
    /// takes effect with no restart; returns true only if the router ENDPOINT (host/port) changed
    /// and the listener needs re-binding.
    @discardableResult
    func reloadIfChangedExternally() -> Bool {
        guard let m = fileMtime(), m > lastMtime else { return false }
        lastMtime = m
        guard let data = try? Data(contentsOf: url),
              let fresh = try? JSONDecoder().decode(AppConfig.self, from: data) else { return false }
        let same = fresh.compressionProxyURL == config.compressionProxyURL
            && fresh.router.host == config.router.host
            && fresh.router.port == config.router.port
            && fresh.backendPort == config.backendPort
            && fresh.mtplxBinary == config.mtplxBinary
            && fresh.webTools.enabled == config.webTools.enabled
        if same { return false }
        let endpointChanged = fresh.router.host != config.router.host || fresh.router.port != config.router.port
        let oldBackendPort = config.backendPort
        config = fresh
        LogStore.shared.log("config.json changed on disk — reloaded (endpoint changed: \(endpointChanged))")
        NotificationCenter.default.post(name: .configChanged, object: nil)
        if oldBackendPort != fresh.backendPort {
            NotificationCenter.default.post(name: .backendPortChanged, object: nil,
                                            userInfo: ["old": oldBackendPort])
        }
        return endpointChanged
    }

    func update(_ mutate: (inout AppConfig) -> Void) {
        var c = config; mutate(&c); save(c)
    }

    private static func persist(_ cfg: AppConfig, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(cfg) { try? data.write(to: url) }
    }

    /// Resolve a client-requested model string (id or alias) to a configured, enabled entry.
    func modelEntry(forRequested requested: String) -> ModelEntry? {
        let r = requested.lowercased()
        return config.models.first { $0.enabled && ($0.id.lowercased() == r || $0.alias.lowercased() == r) }
    }
}
