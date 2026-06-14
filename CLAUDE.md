# CLAUDE.md

## What this is

A Railway deployment template for [Hermes Agent](https://github.com/NousResearch/hermes-agent).
It is a thin admin server that wraps the upstream `hermes` CLI: a web setup
wizard, gateway lifecycle management, user pairing, and a reverse proxy that
fronts Hermes's own dashboard behind a single authenticated port. The agent
itself is **not** in this repo — it is installed from upstream in the
`Dockerfile`; this repo is only the wrapper.

- `server.py` — the entire admin server (Starlette + Uvicorn ASGI app). One file.
- `templates/index.html` — the setup UI, an Alpine.js SPA with no build step.
- `Dockerfile` — installs the pinned `hermes-agent` release and pre-builds its
  React/TUI assets at image-build time.
- `start.sh` — container entrypoint; seeds `$HERMES_HOME`, then execs `server.py`.

## Run / develop

There is no local dev server or test suite. The app only runs meaningfully
inside its container (it shells out to the `hermes` CLI):

```bash
docker build -t hermes-agent .
docker run --rm -it -p 8080:8080 -e PORT=8080 -e ADMIN_PASSWORD=changeme \
  -v hermes-data:/data hermes-agent
# open http://localhost:8080 — log in as admin / changeme
```

In production, Railway builds the `Dockerfile` and runs `start.sh` (see
`railway.toml`); a volume must be mounted at `/data` to persist config.

## Architecture

`server.py` starts two child processes in its lifespan context (`Gateway` and
`Dashboard` classes), then serves on `$PORT`:
- `hermes gateway` — the agent that services messaging channels.
- `hermes dashboard` — Hermes's native UI, bound to loopback on
  `HERMES_DASHBOARD_PORT` (default 9119).

Everything is routed through `server.py`: `/setup` (wizard) and `/setup/api/*`
(config, status, logs, gateway control, pairing, xAI OAuth) are handled
locally; everything else is reverse-proxied to the loopback dashboard
(including the `/api/pty`, `/api/ws`, `/api/events` WebSockets). The only
unauthenticated routes are `/health`, `/login`, and `/logout` (`PUBLIC_PATHS`).

A fourth dashboard WebSocket, `/api/pub`, is **intentionally not proxied** — it
is the PTY child's loopback-only event-injection channel, and exposing it would
let an authed user spam channels. Don't add it to the proxy.

Both child processes stream stdout into in-memory ring buffers, but only the
**gateway** buffer is exposed via the Logs API (`/setup/api/logs`); the
dashboard buffer goes to container stdout only. There is no log file.

## Config persistence

All runtime config lives under `$HERMES_HOME` (`/data/.hermes` in the container),
written by `server.py`, not committed here:
- `.env` — provider keys, model, channel/tool settings (the `ENV_VARS` registry
  near the top of `server.py` defines what the UI shows).
- `config.yaml` — **deep-merged** with the existing file on write
  (`write_config_yaml`). Deployment-managed keys (`model.default`, `terminal`,
  `agent`, `data_dir`, custom providers) are authoritatively overwritten; other
  user-managed sections (e.g. `mcp_servers`) are preserved. Don't replace the
  merge with an overwrite.
- `auth.json` — xAI OAuth tokens. `pairing/*.json` — device pairing state.

`.env` values take priority over Railway/process env vars: the gateway is
launched with `read_env(ENV_FILE)` merged *over* `os.environ` so Hermes's own
dotenv loading can't shadow them.

## Things to get right

- **Auth is HMAC-signed cookies, not Basic Auth** (see the comment block above
  `guard()` for why). The signing secret is regenerated on every process start,
  so any redeploy or restart invalidates all sessions — this is intended.
- The reverse proxy deliberately **keeps** `authorization` and `cookie` headers
  and strips only `host`/`transfer-encoding`. A previous over-aggressive strip
  masked upstream 401s; don't reintroduce it.
- WebSocket auth is verified at the edge (HMAC cookie) before connecting
  upstream; Hermes's own WS auth is token-in-query, so upstream headers are not
  forwarded.
- When writing `config.yaml`, `model.provider` is forced to `"auto"` **only if a
  known API key is set**. With no API key the user is likely on an OAuth provider
  (`xai-oauth`, `qwen-oauth`, …) chosen in the dashboard — overwriting it to
  `"auto"` on restart would break their session. Preserve that conditional.
- `Dockerfile` pins `HERMES_REF` (a `vYYYY.M.D` tag) and pre-builds Hermes's
  React + TUI assets at image time. `HERMES_TUI_DIR` points Hermes at that
  pre-built bundle so the `/api/pty` chat doesn't trigger a 30–60s npm build on
  first connect. When bumping the ref, re-check upstream `pyproject.toml` extras
  and the minimum-version comments next to the `--tui` / `--skip-build` flags in
  `server.py`.
- `start.sh` removes a stale `gateway.pid` on every boot — `hermes gateway`
  leaves it on the persistent volume and a leftover file blocks the next start.
- The container runs under `tini` (PID 1) to reap zombies from tool-spawned
  grandchild processes; don't drop it from the `Dockerfile`.

## Stale docs warning

The `README.md` Features list says "Basic Auth" and its architecture sketch
predates the cookie auth and the proxied native dashboard. Some docstrings
*inside* `server.py` also still say "basic auth" (e.g. on `Dashboard` and
`_proxy_to_dashboard`). The actual mechanism is HMAC cookies — trust the
`guard()` / cookie code over any "basic auth" prose anywhere.
