import Foundation

struct OpenCodeWriteResult {
    let path: String
    let backupPath: String?
    let createdNew: Bool
    let warnings: [String]
    let carriedSettings: Bool
}

/// Writes (non-destructively, with backup) an OpenCode provider that points at the
/// router, and wires plan/build agents to planner/builder. Carries over per-model
/// settings (limit/reasoning/tool_call/temperature/modalities) and provider options
/// from any existing providers it supersedes, so nothing the user tuned is lost.
enum OpenCodeConfigWriter {
    static var configURL: URL {
        URL(fileURLWithPath: expandTilde("~/.config/opencode/opencode.json"))
    }

    @discardableResult
    static func write() throws -> OpenCodeWriteResult {
        let cfg = ConfigStore.shared.config
        let enabled = cfg.models.filter { $0.enabled }
        guard !enabled.isEmpty else {
            throw RouterError.badRequest("no enabled models to write — add or enable a model first")
        }

        let url = configURL
        var warnings: [String] = []
        var backupPath: String? = nil
        var createdNew = false
        var root: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)   // surfaces permission errors
            let bak = url.deletingLastPathComponent()
                .appendingPathComponent("opencode.json.bak-mtplxrouter-\(stamp())")
            try? data.write(to: bak); backupPath = bak.path
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                root = obj
            } else {
                warnings.append("existing opencode.json was not valid JSON — wrote a fresh config; the old file is backed up.")
            }
        } else {
            createdNew = true
        }

        let base = "http://\(cfg.router.host):\(cfg.router.port)/v1"
        let ourIds = Set(enabled.map { $0.id })
        var providers = root["provider"] as? [String: Any] ?? [:]

        // Providers we supersede: any provider (other than our own "mtplx") whose
        // models overlap ours — that's where the user's per-model tuning lives.
        var sources: [(String, [String: Any])] = []
        for (name, pv) in providers {
            guard name != "mtplx", let p = pv as? [String: Any],
                  let pm = p["models"] as? [String: Any] else { continue }
            if !Set(pm.keys).isDisjoint(with: ourIds) { sources.append((name, p)) }
        }
        sources.sort { $0.0 < $1.0 }   // deterministic merge order

        // Provider-level options: router baseURL + carried options (headers, timeouts…).
        var options: [String: Any] = ["baseURL": base]
        for (_, p) in sources {
            if let opts = p["options"] as? [String: Any] {
                for (k, v) in opts where k != "baseURL" && k != "apiKey" { options[k] = v }
            }
        }
        if !cfg.router.apiKey.isEmpty { options["apiKey"] = cfg.router.apiKey }

        // Per-model entries: carry the matching source model's settings, set our name,
        // and default reasoning/tool_call on so agentic use keeps working.
        var carried = false
        var models: [String: Any] = [:]
        for m in enabled {
            var entry: [String: Any] = [:]
            for (_, p) in sources {
                if let pm = p["models"] as? [String: Any], let src = pm[m.id] as? [String: Any] {
                    entry = src; carried = true; break
                }
            }
            entry["name"] = m.displayName
            if entry["tool_call"] == nil { entry["tool_call"] = true }
            if entry["reasoning"] == nil { entry["reasoning"] = true }
            models[m.id] = entry
        }

        providers["mtplx"] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "MTPLX Router",
            "options": options,
            "models": models,
        ]
        root["provider"] = providers

        // Agents: only set `model`, preserve prompt/temperature and everything else.
        let planner = enabled.first { $0.alias == "planner" } ?? enabled.first
        let builder = enabled.first { $0.alias == "builder" } ?? enabled.first
        var agent = root["agent"] as? [String: Any] ?? [:]
        if let planner = planner {
            var plan = agent["plan"] as? [String: Any] ?? [:]
            plan["model"] = "mtplx/\(planner.id)"; agent["plan"] = plan
        }
        if let builder = builder {
            var build = agent["build"] as? [String: Any] ?? [:]
            build["model"] = "mtplx/\(builder.id)"; agent["build"] = build
        }
        root["agent"] = agent
        if let builder = builder {
            root["model"] = "mtplx/\(builder.id)"
            root["small_model"] = "mtplx/\(builder.id)"
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url)
        LogStore.shared.log("wrote OpenCode config → \(url.path) (carried per-model settings: \(carried))")
        return OpenCodeWriteResult(path: url.path, backupPath: backupPath,
                                   createdNew: createdNew, warnings: warnings, carriedSettings: carried)
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }
}
