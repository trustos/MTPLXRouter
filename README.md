# MTPLX Router

A tiny macOS **menu-bar app** that puts one stable OpenAI-compatible endpoint in
front of **MTPLX** and **lazy-loads / swaps** model daemons on demand.

MTPLX serves one model per daemon and has no built-in router or hot-swap. This app
adds that: OpenCode (or any OpenAI client) addresses several models through a single
URL while only **one model is resident at a time** (*strict swap*).

## Why
- Keeps MTPLX's tuned **MTP speculative decoding** — the app calls `mtplx quickstart`,
  which auto-applies your per-model tuned depth + sampler + chat template.
- One model loaded → each gets full context and you reclaim RAM between models.
- Seamless: a request for a not-loaded model **blocks ~7 s while it swaps**, then streams.

## Build & install
```sh
make install        # build + replace the app in /Applications + relaunch  ← one-command update
make bundle         # just build dist/MTPLX Router.app (no install)
make run            # run the dev binary in the foreground
make doctor         # print diagnostics (mtplx, models, ports)
make help           # list all targets
```
`make install` is the single command to refresh the installed app: it quits any running
instance (cleanly freeing the loaded model), rebuilds, copies into `/Applications`, and
relaunches. Needs the Swift toolchain — Command-Line Tools is enough, no Xcode required.

## Use
- Click the menu-bar **⚡︎** icon: current model + RAM, load/unload a model,
  start/stop the router, **Write OpenCode config**, open logs, Settings…
- Point any OpenAI client at `http://127.0.0.1:11435/v1` and request a model by its
  **id** or **alias** (`planner` / `builder`).

```sh
curl http://127.0.0.1:11435/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"builder","messages":[{"role":"user","content":"hi"}],"stream":true}'
```

## OpenCode
Menu → **Write OpenCode config** (or the Settings button) adds an `mtplx` provider
pointing at the router and wires `plan`→planner, `build`→builder. It **backs up**
your `~/.config/opencode/opencode.json` first and preserves your prompts/temperature.

## Web tools (private, local)
Menu → **Set up web tools…** (or `MTPLX Router --setup-web-tools`) installs a small private
Python venv and exposes two tools to OpenCode as a local **MCP it spawns on demand** — no
Docker, no resident daemon, nothing through a third-party service:

- `web_search` — DuckDuckGo via [`ddgs`](https://pypi.org/project/ddgs/) (no API key)
- `web_fetch` — [Crawl4AI](https://github.com/unclecode/crawl4ai) (headless Chromium → clean
  markdown), which gets past the bot-blocking (Medium/Cloudflare 403s, Google CAPTCHA) that
  defeats OpenCode's built-in WebFetch.

The venv + `server.py` live under `…/MTPLX Router/web-tools/`; the router writes an
`mcp.mtplx-web` entry into `opencode.json` (non-destructive). **Restart OpenCode** after
enabling. First install downloads Chromium (a few minutes). Search is DuckDuckGo; a local
SearXNG (multi-engine) is a possible future upgrade.

## Config
`~/Library/Application Support/MTPLX Router/config.json`

| key | default | notes |
|---|---|---|
| `router.host` / `router.port` | `127.0.0.1` / `11435` | the endpoint clients hit |
| `router.apiKey` | "" | blank = no auth (localhost) |
| `backendPort` | `8011` | reused by whichever model is loaded |
| `mtplxBinary` | `~/.mtplx/bin/mtplx` | **keep this** so your tunes apply |
| `models[]` | 27B `planner`, 35B `builder` | `id`, `alias`, `displayName`, `path`, `enabled` |
| `startup.*` | router on, no preload | `launchAtLogin`, `startRouterOnLaunch`, `preloadModelId` |
| `healthTimeoutSeconds` | 180 | max wait for a daemon to come up |
| `idleEvictMinutes` | 0 | 0 = never auto-unload |
| `webTools.*` | off | local `web_search`/`web_fetch` MCP for OpenCode (`enabled`, `pythonPath`, `maxResults`) |

## Launch at login
Menu → **Launch at login** (uses `SMAppService`). For this to stick, keep the app at a
stable path — move `MTPLX Router.app` to `/Applications` first, then enable it.

## How it works
- `RouterServer` (Network.framework) accepts on the router port, reads the request,
  resolves the body's `model` (id/alias) → a configured entry, asks `DaemonManager` to
  ensure that model is up, then **relays bytes verbatim** (works for JSON and SSE).
- `DaemonManager` runs `mtplx quickstart …` as a child it owns, health-checks
  `:8011/v1/models`, and on a switch stops the current daemon (`mtplx stop` + terminate
  + port-kill fallback) before starting the next.
- SIGTERM/SIGINT and **Quit** stop the daemon, so a closed app never orphans a model.

## Logs
`~/Library/Application Support/MTPLX Router/logs/` — `router.log`, `daemon.log`.

## Status
MVP. Verified end-to-end: model aggregation (no load), cold load + relay (~7 s),
plan↔build strict swap (~7 s), streaming SSE passthrough, clean shutdown (no orphan).
Deferred (smart defaults for now): per-model KV-memory estimator, advanced sampler/
KV-quant/prefill knobs, live tok/s in the menu bar.
