import Foundation

extension Notification.Name {
    static let configChanged = Notification.Name("mtplx.router.configChanged")
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

    init() {}
    enum CodingKeys: String, CodingKey {
        case router, backendPort, compressionProxyURL, mtplxBinary, modelsDir, startup, models, healthTimeoutSeconds, idleEvictMinutes
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
    }

    func save(_ cfg: AppConfig) {
        config = cfg
        ConfigStore.persist(cfg, to: url)
        NotificationCenter.default.post(name: .configChanged, object: nil)
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
