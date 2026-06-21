import AppKit

// Headless modes (no UI) — handy for testing and scripting.
let args = CommandLine.arguments
if args.contains("--write-opencode") {
    if !args.contains("--force") {
        print("opencode.json is managed by ccstack — run `ccstack apply` instead.")
        print("(re-run with --force to write it standalone anyway.)")
        exit(0)
    }
    do {
        let r = try OpenCodeConfigWriter.write()
        print("OK  wrote \(r.path) (standalone, bypassing ccstack)")
        if let b = r.backupPath { print("    backup: \(b)") }
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
