import Foundation

/// Local web tools for OpenCode: a private, self-hosted stdio MCP exposing
/// `web_search` (DuckDuckGo via ddgs) and `web_fetch` (Crawl4AI headless browser).
/// We own a tiny Python venv + server script; OpenCode spawns the server on demand,
/// so nothing runs at idle and no third-party service sits in the path.
///
/// NB: the support-dir path contains a space ("MTPLX Router"), so every Python call
/// goes through `<venv>/bin/python -m <module>` — never the console-script shebangs
/// (pip / playwright), which break on spaces in the interpreter path.
enum WebToolsManager {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MTPLX Router", isDirectory: true)
            .appendingPathComponent("web-tools", isDirectory: true)
    }
    static var venvPython: URL { dir.appendingPathComponent("venv/bin/python") }
    static var serverScript: URL { dir.appendingPathComponent("server.py") }

    /// True once the venv interpreter and the server script both exist.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: venvPython.path)
            && FileManager.default.fileExists(atPath: serverScript.path)
    }

    /// The opencode.json `mcp` entry pointing OpenCode at the local server (stdio).
    static func mcpEntry() -> [String: Any] {
        ["type": "local", "command": [venvPython.path, serverScript.path], "enabled": true]
    }

    enum WebToolsError: Error, CustomStringConvertible {
        case pythonMissing(String)
        case step(String, Int32)
        var description: String {
            switch self {
            case .pythonMissing(let p):
                return "Python not found at \(p) — install it (brew install python@3.13)."
            case .step(let label, let code):
                return "\(label) failed (exit \(code)). See web-tools/install.log."
            }
        }
    }

    /// Build the venv, install deps, and write the server script. Idempotent: safe to
    /// re-run; skips venv creation if the interpreter already exists. Slow (pip + Chromium)
    /// — call off the main thread. `python` creates the venv (e.g. python@3.13).
    static func install(python: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Always (re)write the server — we own it; it's the source of truth.
        try SERVER_PY.data(using: .utf8)!.write(to: serverScript)
        LogStore.shared.log("web-tools: wrote \(serverScript.lastPathComponent)")

        if !fm.isExecutableFile(atPath: venvPython.path) {
            guard fm.isExecutableFile(atPath: python) else { throw WebToolsError.pythonMissing(python) }
            LogStore.shared.log("web-tools: creating venv (\(python))…")
            try run(python, ["-m", "venv", dir.appendingPathComponent("venv").path], "venv create")
        }
        let py = venvPython.path
        LogStore.shared.log("web-tools: installing fastmcp ddgs crawl4ai (a few minutes)…")
        _ = runStep(py, ["-m", "pip", "install", "-q", "--upgrade", "pip"])  // best-effort
        try run(py, ["-m", "pip", "install", "-q", "fastmcp", "ddgs", "crawl4ai"], "pip install")
        LogStore.shared.log("web-tools: installing chromium…")
        try run(py, ["-m", "playwright", "install", "chromium"], "playwright install chromium")
        LogStore.shared.log("web-tools: install complete ✓")
    }

    /// Remove the venv + script (when disabling the feature).
    static func uninstall() {
        try? FileManager.default.removeItem(at: dir)
        LogStore.shared.log("web-tools: removed \(dir.path)")
    }

    // MARK: - process helpers (mirror DaemonManager's Process usage; output → install.log)

    @discardableResult
    private static func runStep(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let logURL = dir.appendingPathComponent("install.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            p.standardOutput = fh
            p.standardError = fh
        }
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func run(_ exe: String, _ args: [String], _ label: String) throws {
        let code = runStep(exe, args)
        if code != 0 { throw WebToolsError.step(label, code) }
    }

    /// The validated MCP server (search via ddgs, fetch via crawl4ai). Embedded so the
    /// app owns the glue — the only upstream deps are the maintained crawl4ai + ddgs.
    /// Written flush-left so Swift's multiline string strips no indentation (preserving
    /// Python's own indentation exactly).
    static let SERVER_PY = #"""
#!/usr/bin/env python3
"""MTPLX Router local web tools — a stdio MCP exposing private, self-hosted
web_search (multi-engine metasearch via ddgs) and web_fetch (Crawl4AI headless browser).

OpenCode spawns this on demand. Nothing here goes through a third-party service —
only your machine talks to the target sites/engines. Heavy imports are lazy so
server startup stays instant; the browser only launches on the first web_fetch.
"""
from __future__ import annotations

from fastmcp import FastMCP

mcp = FastMCP("mtplx-web")


@mcp.tool()
def web_search(query: str, max_results: int = 5) -> list[dict]:
    """Private metasearch across multiple engines (Google, Bing, Brave, DuckDuckGo,
    Mojeek, …) via ddgs — no API key, no third-party service.

    Returns a list of {title, url, snippet}.
    """
    from ddgs import DDGS

    results: list[dict] = []
    with DDGS() as ddgs:
        for r in ddgs.text(query, max_results=max_results, backend="auto"):
            results.append(
                {
                    "title": r.get("title"),
                    "url": r.get("href") or r.get("url") or r.get("link"),
                    "snippet": r.get("body") or r.get("snippet"),
                }
            )
    return results


@mcp.tool()
async def web_fetch(url: str) -> str:
    """Fetch a URL and return clean markdown, rendering JS in a real headless
    browser so it gets past sites that block plain HTTP fetchers (Medium,
    Cloudflare, etc.).
    """
    from crawl4ai import AsyncWebCrawler

    async with AsyncWebCrawler() as crawler:
        result = await crawler.arun(url=url)
    if not getattr(result, "success", False):
        return f"ERROR fetching {url}: {getattr(result, 'error_message', 'unknown error')}"
    md = result.markdown
    return getattr(md, "raw_markdown", None) or str(md)


if __name__ == "__main__":
    mcp.run(transport="stdio")
"""#
}
