import Foundation

/// A user-facing problem with an actionable fix.
struct Issue: Identifiable {
    enum Severity { case error, warning }
    let id = UUID()
    let severity: Severity
    let title: String
    let detail: String
    static func error(_ t: String, _ d: String) -> Issue { .init(severity: .error, title: t, detail: d) }
    static func warning(_ t: String, _ d: String) -> Issue { .init(severity: .warning, title: t, detail: d) }
    var glyph: String { severity == .error ? "⛔︎" : "⚠︎" }
}

enum Diagnostics {
    static func mtplxIsInstalled(_ cfg: AppConfig) -> Bool {
        FileManager.default.isExecutableFile(atPath: cfg.mtplxBinary)
    }

    /// Pure config/filesystem checks (no network, no lsof) — safe to call often / on edits.
    static func configIssues(_ cfg: AppConfig) -> [Issue] {
        var issues: [Issue] = []

        // mtplx CLI
        let bin = cfg.mtplxBinary
        if !FileManager.default.fileExists(atPath: bin) {
            issues.append(.error("MTPLX not found",
                "No mtplx CLI at “\(bin)”. Install MTPLX, or set the correct path in Settings ▸ Router."))
        } else if !FileManager.default.isExecutableFile(atPath: bin) {
            issues.append(.error("MTPLX not executable",
                "“\(bin)” exists but isn’t executable. Run chmod +x, or fix the path in Settings ▸ Router."))
        }

        // models
        if cfg.models.isEmpty {
            issues.append(.error("No models configured",
                "Add a model in Settings ▸ Models — an id, an alias, and the folder path under ~/.mtplx/models."))
        } else {
            let enabled = cfg.models.filter { $0.enabled }
            if enabled.isEmpty {
                issues.append(.warning("All models disabled",
                    "Enable at least one model in Settings ▸ Models, or clients have nothing to call."))
            }
            for m in enabled where !FileManager.default.fileExists(atPath: m.path) {
                issues.append(.warning("Model folder missing",
                    "“\(m.displayName)” → “\(m.path)” doesn’t exist. Fix the path in Settings ▸ Models."))
            }
            let ids = cfg.models.map { $0.id.lowercased() }
            if Set(ids).count != ids.count {
                issues.append(.warning("Duplicate model ids",
                    "Two models share an id; routing always picks the first. Make ids unique in Settings ▸ Models."))
            }
            if let pre = cfg.startup.preloadModelId, !pre.isEmpty,
               !cfg.models.contains(where: { $0.id == pre }) {
                issues.append(.warning("Preload model missing",
                    "Startup preload is set to “\(pre)”, which isn’t in your models. Update it in Settings ▸ Startup."))
            }
        }
        return issues
    }

    /// Full check: config + live runtime state (port held, router bound).
    static func run() -> [Issue] {
        let cfg = ConfigStore.shared.config
        var issues = configIssues(cfg)

        if DaemonManager.shared.loadedModelId == nil, let pid = pidListening(onPort: cfg.backendPort) {
            issues.append(.warning("Backend port in use",
                "Port \(cfg.backendPort) is held by pid \(pid) (not started by the router). Change the backend port in Settings, or use “Free backend port” in the menu."))
        }
        if !RouterServer.shared.isRunning, let e = RouterServer.shared.lastError {
            issues.append(.error("Router not listening", e))
        }
        return issues
    }

    static var blockingErrors: [Issue] { run().filter { $0.severity == .error } }
    static var blockingConfigErrors: [Issue] {
        configIssues(ConfigStore.shared.config).filter { $0.severity == .error }
    }
}
