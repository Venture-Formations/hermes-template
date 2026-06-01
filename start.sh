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

# --- gbrain boot-task runner (Railway-MCP-drivable; no `railway ssh` needed) --
# Container-side gbrain maintenance you can trigger purely through the Railway
# MCP (which has no exec/ssh tool): set the GBRAIN_BOOT_TASK service variable
# (set_variables) -> Railway redeploys -> this block runs the task on boot and
# prints [gbrain-boot-task] lines to stdout -> read them with get_logs. This is
# the MCP-only substitute for `railway ssh "gbrain ..."`.
#
# Set GBRAIN_BOOT_TASK=post-upgrade *persistently* to self-heal on every rebuild
# (so the daily GBRAIN_REF bump becomes end-to-end). All tasks are idempotent:
# post-upgrade is a no-op when migrations are current; `ALTER ... ENABLE RLS` on
# an already-protected table is a no-op; doctor is read-only. Runs BEFORE the
# autopilot daemon launches so schema DDL happens on a quiet DB (no lock
# contention). Strictly non-fatal — never blocks the gateway.
(
  set +e
  if [ -n "${GBRAIN_BOOT_TASK}" ] && command -v gbrain >/dev/null 2>&1; then
    btlog() { echo "[gbrain-boot-task] $*"; }
    btlog "task=${GBRAIN_BOOT_TASK} starting"
    cd /data/brain 2>/dev/null || cd /data
    case "${GBRAIN_BOOT_TASK}" in
      post-upgrade|selfheal)
        # 3-min cap: this runs before the gateway, and Railway's healthcheck
        # window is ~5 min — a hung post-upgrade must never block boot. A real
        # upgrade is fast; if a huge migration ever needs longer, the next boot
        # (or the daily routine) retries. The block is also `|| true` (non-fatal).
        GBRAIN_POST_UPGRADE_TIMEOUT_MS=180000 gbrain post-upgrade 2>&1 | sed 's/^/[gbrain-boot-task] /'
        # Enable RLS on any public table missing it — Supabase grants no superuser,
        # so gbrain's auto-RLS event trigger can't install and migration-created
        # tables don't get RLS automatically. Idempotent. (Quoted heredoc so the
        # bun snippet is taken literally — no shell expansion of $ / backticks.)
        if [ -n "${DATABASE_URL}" ]; then
          cat > /tmp/_gbrain_rls.ts <<'RLSEOF'
const { SQL } = require("bun");
const sql = new SQL(process.env.DATABASE_URL);
const rows = await sql.unsafe("SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity");
for (const t of rows) { await sql.unsafe(`ALTER TABLE "public"."${t.relname}" ENABLE ROW LEVEL SECURITY`); console.log("RLS enabled:", t.relname); }
if (!rows.length) console.log("RLS: all public tables already protected");
await sql.end();
RLSEOF
          bun /tmp/_gbrain_rls.ts 2>&1 | sed 's/^/[gbrain-boot-task] /'
        fi
        gbrain doctor 2>&1 | grep -iE '\[FAIL\]|Overall health|brain_score' | sed 's/^/[gbrain-boot-task] /'
        ;;
      doctor)
        gbrain doctor 2>&1 | grep -iE '\[FAIL\]|\[WARN\]|Overall health|brain_score' | sed 's/^/[gbrain-boot-task] /'
        ;;
      verify)
        bash /data/scripts/verify-upgrade.sh 2>&1 | sed 's/^/[gbrain-boot-task] /'; btlog "verify-upgrade exit=$?"
        ;;
      *)
        btlog "unknown task ${GBRAIN_BOOT_TASK} (known: post-upgrade|doctor|verify) — skipping"
        ;;
    esac
    btlog "task=${GBRAIN_BOOT_TASK} done"
  fi
) || true

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

# --- gbrain HTTP MCP server (remote MCP for claude.ai / Cowork etc.) --------
# Exposes the brain over MCP at https://gbrain.ventureformations.com/mcp
# (Railway custom domain -> this container's port 8787). Canonical refs
# (github.com/garrytan/gbrain @ master): docs/mcp/DEPLOY.md + docs/mcp/CLAUDE_COWORK.md.
#   - --bind 0.0.0.0 is REQUIRED for remote clients (default is 127.0.0.1 since
#     v0.34.1, which would refuse the Railway edge).
#   - --public-url sets the OAuth issuer in discovery metadata to the public host
#     (RFC 8414 §3.3) so it matches what clients hit.
#   - GBRAIN_HTTP_TRUST_PROXY=1: gbrain sits behind Railway's TLS-terminating
#     proxy (one hop); express-rate-limit otherwise rejects the X-Forwarded-For.
# Long-lived foreground server, so we nohup-background it explicitly. Non-fatal:
# a serve hiccup must never block the Hermes gateway (set +e + `|| true`).
(
  set +e
  if command -v gbrain >/dev/null 2>&1; then
    echo "[gbrain-serve] launching HTTP MCP server on :8787 (public https://gbrain.ventureformations.com/mcp)"
    # --enable-dcr: claude.ai (and other hosted MCP clients) self-register via
    # RFC 7591 Dynamic Client Registration; gbrain disables it by default.
    # Safe because the /authorize consent is gated by GBRAIN_ADMIN_BOOTSTRAP_TOKEN
    # (set as a Railway service var) — open registration, owner-gated approval.
    GBRAIN_HTTP_TRUST_PROXY="${GBRAIN_HTTP_TRUST_PROXY:-1}" \
      nohup gbrain serve --http --bind 0.0.0.0 --port 8787 \
        --public-url https://gbrain.ventureformations.com \
        --enable-dcr \
        > /tmp/gbrain-serve.log 2>&1 &
    echo "[gbrain-serve] pid $! — logs at /tmp/gbrain-serve.log"
  else
    echo "[gbrain-serve] WARN: gbrain not on PATH; skipping MCP server"
  fi
) || true

exec python /app/server.py
