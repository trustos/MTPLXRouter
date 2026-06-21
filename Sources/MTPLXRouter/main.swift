import AppKit

// Headless modes (no UI) — handy for testing and scripting.
let args = CommandLine.arguments
if args.contains("--write-opencode") {
    do {
        let r = try OpenCodeConfigWriter.write()
        print("OK  wrote \(r.path) (\(r.fromMtplx ? "canonical from mtplx" : "built-in canonical fallback"))")
        if let b = r.backupPath { print("    backup: \(b)") }
        for w in r.warnings { print("    warning: \(w)") }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
if args.contains("--setup-web-tools") {
    do {
        let cfg = ConfigStore.shared.config
        print("setting up web tools (venv + crawl4ai + chromium; can take a few minutes)…")
        try WebToolsManager.install(python: cfg.webTools.pythonPath)
        ConfigStore.shared.update { $0.webTools.enabled = true }
        let r = try OpenCodeConfigWriter.write()
        print("OK  web tools installed; wrote \(r.path) with mcp.mtplx-web")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
if args.contains("--doctor") {
    let issues = Diagnostics.run()
    if issues.isEmpty { print("No issues found.") }
    for i in issues { print("[\(i.severity == .error ? "ERROR" : "warn ")] \(i.title) — \(i.detail)") }
    exit(issues.contains { $0.severity == .error } ? 1 : 0)
}

// Menu-bar-only (accessory) app: no Dock icon, lives in the status bar.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
