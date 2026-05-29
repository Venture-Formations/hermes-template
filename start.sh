#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace /data/.hermes/skins /data/.hermes/plans \
         /data/.hermes/home

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
# Set HERMES_AUTH_JSON_BOOTSTRAP to the contents of a locally-generated
# ~/.hermes/auth.json. Written only once — subsequent token refreshes update
# the file in place on the persistent volume.
if [ ! -f /data/.hermes/auth.json ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > /data/.hermes/auth.json
  chmod 600 /data/.hermes/auth.json
fi

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

# --- gbrain autopilot bootstrap (canonical ephemeral-container launch) -----
# gbrain is baked into the image at /usr/local/bun/bin (see Dockerfile). On
# Railway, gbrain detects an ephemeral container (RAILWAY_ENVIRONMENT is set)
# and its canonical launch mechanism is:
#   1. `gbrain autopilot --install` writes ~/.gbrain/start-autopilot.sh
#   2. the agent's bootstrap runs `bash ~/.gbrain/start-autopilot.sh` on every
#      container start, which nohup-backgrounds the autopilot supervisor.
# Refs (github.com/garrytan/gbrain @ master):
#   - skills/setup/SKILL.md Phase C.5 ("gbrain autopilot --install ... On
#     ephemeral containers (Render / Railway / Fly / Docker): writes
#     ~/.gbrain/start-autopilot.sh").
#   - src/commands/autopilot.ts installEphemeralContainer() — emits the
#     `bash <scriptPath>` one-liner and nohup-launches the wrapper (non-blocking).
# We pass --no-inject because we are NOT OpenClaw; we launch the daemon
# explicitly below instead of having gbrain edit a bootstrap hook.
# This block is idempotent (install is safe to re-run; the start script
# re-launches the daemon each boot) and strictly non-fatal: any failure is
# logged and must never block the gateway from starting. `set -e` is disabled
# for the block so a gbrain hiccup can't take the whole container down.
(
  set +e
  if command -v gbrain >/dev/null 2>&1; then
    echo "[gbrain] $(gbrain --version 2>/dev/null) — installing autopilot (ephemeral-container, --no-inject)"
    gbrain autopilot --install --no-inject 2>&1 | sed 's/^/[gbrain] /'
    if [ -f "$HOME/.gbrain/start-autopilot.sh" ]; then
      echo "[gbrain] launching autopilot daemon via $HOME/.gbrain/start-autopilot.sh"
      bash "$HOME/.gbrain/start-autopilot.sh" 2>&1 | sed 's/^/[gbrain] /' || \
        echo "[gbrain] WARN: start-autopilot.sh exited non-zero; continuing without autopilot"
    else
      echo "[gbrain] WARN: ~/.gbrain/start-autopilot.sh not found after --install; skipping daemon launch"
    fi
  else
    echo "[gbrain] WARN: gbrain not on PATH; skipping autopilot bootstrap"
  fi
) || true

exec python /app/server.py
