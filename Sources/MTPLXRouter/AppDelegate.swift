import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var settingsWC: SettingsWindowController?
    private var signalSources: [DispatchSourceSignal] = []
    private var routerErrorShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "MTPLX Router")
            btn.imagePosition = .imageLeading
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        DaemonManager.shared.onStateChange = { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }
        RouterServer.shared.onStateChange = { [weak self] running, error in
            DispatchQueue.main.async {
                self?.updateButton()
                if running { self?.routerErrorShown = false }
                else if let error = error, self?.routerErrorShown == false {
                    self?.routerErrorShown = true
                    self?.alert("Router didn’t start", error, settings: true)
                }
            }
        }

        let cfg = ConfigStore.shared.config
        if cfg.startup.startRouterOnLaunch { startRouter() }

        // Only attempt a preload when the config is actually usable.
        if Diagnostics.blockingConfigErrors.isEmpty,
           let pre = cfg.startup.preloadModelId, !pre.isEmpty,
           cfg.models.contains(where: { $0.id == pre && $0.enabled }) {
            DispatchQueue.global(qos: .userInitiated).async { try? DaemonManager.shared.ensure(modelId: pre) }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        installSignalHandlers()
        NotificationCenter.default.addObserver(forName: .mtplxWebToolsSetup, object: nil, queue: .main) { [weak self] _ in
            self?.setupWebTools()
        }
        updateButton()

        // Surface blocking configuration problems right away so the user can act.
        let errs = Diagnostics.blockingConfigErrors
        if !errs.isEmpty { presentIssues(errs) }
    }

    private func startRouter() {
        do { try RouterServer.shared.start() }
        catch {
            LogStore.shared.log("router start error: \(error)")
            alert("Router didn’t start", "\(error)", settings: true)
        }
    }

    private func tick() {
        let dm = DaemonManager.shared
        let cfg = ConfigStore.shared.config
        if cfg.idleEvictMinutes > 0, dm.loadedModelId != nil,
           dm.idleSeconds() > Double(cfg.idleEvictMinutes * 60) {
            LogStore.shared.log("idle evict after \(cfg.idleEvictMinutes)m")
            DispatchQueue.global().async { dm.stop() }
        }
        updateButton()
    }

    private func updateButton() {
        guard let btn = statusItem.button else { return }
        if let first = Diagnostics.blockingConfigErrors.first {
            btn.title = " ⚠"
            btn.toolTip = "\(first.title): \(first.detail)"
            return
        }
        btn.toolTip = nil
        let dm = DaemonManager.shared
        switch dm.state {
        case .ready(let id):
            let alias = ConfigStore.shared.config.models.first { $0.id == id }?.alias
            btn.title = " " + (alias?.isEmpty == false ? alias! : id)
        case .starting: btn.title = " …"
        case .failed:   btn.title = " ⚠︎"
        case .stopped:  btn.title = RouterServer.shared.isRunning ? " idle" : " off"
        }
    }

    // MARK: menu (rebuilt on open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let dm = DaemonManager.shared
        let cfg = ConfigStore.shared.config
        let issues = Diagnostics.run()

        // Problems section first, if any.
        if !issues.isEmpty {
            let h = NSMenuItem(title: "Problems", action: nil, keyEquivalent: ""); h.isEnabled = false
            menu.addItem(h)
            for i in issues {
                let item = NSMenuItem(title: "  \(i.glyph) \(i.title)", action: #selector(openSettings), keyEquivalent: "")
                item.target = self
                item.toolTip = i.detail
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let header = NSMenuItem(title: "Router: \(RouterServer.shared.isRunning ? "on" : "off") · \(cfg.router.host):\(cfg.router.port)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let stateLine: String
        switch dm.state {
        case .ready(let id):
            let ram = dm.currentRSS().map { " · " + humanBytes($0) } ?? ""
            stateLine = "Loaded: \(displayName(id))\(ram)"
        case .starting(let id): stateLine = "Loading: \(displayName(id))…"
        case .failed(let m):    stateLine = "Last error: \(m.prefix(48))"
        case .stopped:          stateLine = "Loaded: none"
        }
        let stateItem = NSMenuItem(title: stateLine, action: nil, keyEquivalent: ""); stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())

        let enabled = cfg.models.filter { $0.enabled }
        let lh = NSMenuItem(title: "Load model", action: nil, keyEquivalent: ""); lh.isEnabled = false
        menu.addItem(lh)
        if enabled.isEmpty {
            let none = NSMenuItem(title: "  (no models — open Settings)", action: #selector(openSettings), keyEquivalent: "")
            none.target = self
            menu.addItem(none)
        } else {
            for m in enabled {
                let item = NSMenuItem(title: "  \(m.displayName)", action: #selector(loadModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m.id
                if dm.loadedModelId == m.id { item.state = .on }
                menu.addItem(item)
            }
        }
        let unload = NSMenuItem(title: "  Unload (free memory)", action: #selector(unload), keyEquivalent: "")
        unload.target = self
        menu.addItem(unload)

        menu.addItem(.separator())

        let routerToggle = NSMenuItem(title: RouterServer.shared.isRunning ? "Stop router" : "Start router",
                                      action: #selector(toggleRouter), keyEquivalent: "")
        routerToggle.target = self
        menu.addItem(routerToggle)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let writeOC = NSMenuItem(title: "Write OpenCode config…", action: #selector(writeOpenCode), keyEquivalent: "")
        writeOC.target = self
        menu.addItem(writeOC)

        let wtOn = ConfigStore.shared.config.webTools.enabled && WebToolsManager.isInstalled
        let webTools = NSMenuItem(title: wtOn ? "Web tools: on ✓" : "Set up web tools…",
                                  action: #selector(setupWebTools), keyEquivalent: "")
        webTools.target = self
        menu.addItem(webTools)

        let freePort = NSMenuItem(title: "Free backend port (\(cfg.backendPort))", action: #selector(freeBackendPort), keyEquivalent: "")
        freePort.target = self
        menu.addItem(freePort)

        let logs = NSMenuItem(title: "Open logs", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MTPLX Router", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func displayName(_ id: String) -> String {
        ConfigStore.shared.config.models.first { $0.id == id }?.displayName ?? id
    }

    // MARK: actions

    @objc private func loadModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try DaemonManager.shared.ensure(modelId: id) }
            catch { DispatchQueue.main.async { self.alert("Couldn’t load model", "\(error)", settings: true) } }
        }
    }
    @objc private func unload() { DispatchQueue.global().async { DaemonManager.shared.stop() } }

    @objc private func toggleRouter() {
        if RouterServer.shared.isRunning { RouterServer.shared.stop() } else { startRouter() }
        updateButton()
    }

    @objc private func toggleLogin() {
        let now = LoginItem.isEnabled
        if LoginItem.set(!now) {
            ConfigStore.shared.update { $0.startup.launchAtLogin = !now }
        } else {
            alert("Couldn’t change launch-at-login",
                  "This needs the app to run from a stable location. Move “MTPLX Router.app” to /Applications and try again.")
        }
    }

    @objc private func writeOpenCode() {
        // The router owns opencode.json — it holds the model list, so it writes its own
        // canonical mtplx provider (reasoning mtplx-owned, output=context, x-mtplx-client)
        // by asking `mtplx connect`. Non-destructive: backs up any existing file first.
        let a = NSAlert()
        a.messageText = "Write OpenCode config?"
        a.informativeText = "Writes the canonical mtplx provider + plan/build agents into ~/.config/opencode/opencode.json, pointed at this router. Your existing file is backed up first."
        a.addButton(withTitle: "Write")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let r = try OpenCodeConfigWriter.write()
            let src = r.fromMtplx ? "canonical (from mtplx)" : "canonical (built-in fallback — mtplx unreachable)"
            alert("OpenCode config written", "Updated \(r.path) — \(src)." + (r.backupPath.map { "\nBackup: \($0)" } ?? ""))
        } catch {
            alert("OpenCode config failed", "\(error)")
        }
    }

    @objc private func setupWebTools() {
        let installed = WebToolsManager.isInstalled
        let enabled = ConfigStore.shared.config.webTools.enabled
        if installed && enabled {
            let a = NSAlert()
            a.messageText = "Web tools are on"
            a.informativeText = "Private web_search + web_fetch (local MCP) are enabled for OpenCode.\n\nDisable them? (The venv is kept; delete the web-tools folder to remove it fully.)"
            a.addButton(withTitle: "Keep enabled")
            a.addButton(withTitle: "Disable")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertSecondButtonReturn else { return }
            ConfigStore.shared.update { $0.webTools.enabled = false }
            do {
                let r = try OpenCodeConfigWriter.write()
                alert("Web tools disabled", "Removed from \(r.path). Restart OpenCode to apply.")
            } catch { alert("Couldn’t update OpenCode config", "\(error)") }
            return
        }
        let a = NSAlert()
        a.messageText = "Set up local web tools?"
        a.informativeText = "Installs a small private Python venv (Crawl4AI + DuckDuckGo) and exposes web_search/web_fetch to OpenCode as a local MCP it spawns on demand. The first install downloads Chromium (a few minutes). Nothing leaves your machine except the page/search traffic itself."
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let py = ConfigStore.shared.config.webTools.pythonPath
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try WebToolsManager.install(python: py)
                DispatchQueue.main.async {
                    ConfigStore.shared.update { $0.webTools.enabled = true }
                    do {
                        let r = try OpenCodeConfigWriter.write()
                        self.alert("Web tools ready", "Installed + wrote \(r.path).\nRestart OpenCode to pick up web_search / web_fetch.")
                    } catch { self.alert("Couldn’t update OpenCode config", "\(error)") }
                }
            } catch {
                DispatchQueue.main.async { self.alert("Web tools setup failed", "\(error)") }
            }
        }
    }

    @objc private func freeBackendPort() {
        let cfg = ConfigStore.shared.config
        let a = NSAlert()
        a.messageText = "Free backend port \(cfg.backendPort)?"
        a.informativeText = "This force-stops whatever is listening on \(cfg.backendPort) (an orphaned or foreign MTPLX daemon). Use this only if a load is stuck or the port is reported in use."
        a.addButton(withTitle: "Free Port")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            DispatchQueue.global().async { DaemonManager.shared.forceFreeBackendPort() }
        }
    }

    @objc private func openLogs() { NSWorkspace.shared.open(LogStore.shared.dir) }

    @objc private func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        DaemonManager.shared.stop()
        RouterServer.shared.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { DaemonManager.shared.stop() }

    // MARK: alerts

    private func presentIssues(_ issues: [Issue]) {
        let body = issues.map { "\($0.glyph) \($0.title)\n   \($0.detail)" }.joined(separator: "\n\n")
        alert("MTPLX Router needs attention", body, settings: true)
    }

    private func alert(_ title: String, _ body: String, settings: Bool = false) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        if settings { a.addButton(withTitle: "Open Settings"); a.addButton(withTitle: "OK") }
        else { a.addButton(withTitle: "OK") }
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        if settings && r == .alertFirstButtonReturn { openSettings() }
    }

    // MARK: signals

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                LogStore.shared.log("received signal \(sig) → clean shutdown")
                DaemonManager.shared.stop()
                RouterServer.shared.stop()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
