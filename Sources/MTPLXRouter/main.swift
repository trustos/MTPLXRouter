import AppKit

// Headless modes (no UI) — handy for testing and scripting.
let args = CommandLine.arguments
if args.contains("--write-opencode") {
    do {
        let r = try OpenCodeConfigWriter.write()
        print("OK  wrote \(r.path)")
        if let b = r.backupPath { print("    backup: \(b)") }
        if r.createdNew { print("    (created a new config)") }
        print("    carried per-model settings from existing providers: \(r.carriedSettings)")
        for w in r.warnings { print("    warning: \(w)") }
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
