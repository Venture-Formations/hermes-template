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
      selfheal-sync)
        # ONE-SHOT brain recovery (set this var, redeploy, read logs, then
        # reset GBRAIN_BOOT_TASK back to `post-upgrade`). Do NOT leave this set
        # persistently — `sync --skip-failed` permanently advances the bookmark
        # past whatever file is currently blocking ingestion, so a poison file
        # that's still on disk gets silently dropped on every rebuild.
        #
        # Order matters: migrations first (a missing column can itself make a
        # cycle phase throw), then name the blocking file(s), then advance the
        # sync bookmark past them so the backlog of good pages finally imports.
        btlog "selfheal-sync: applying pending migrations"
        GBRAIN_POST_UPGRADE_TIMEOUT_MS=180000 gbrain post-upgrade 2>&1 | sed 's/^/[gbrain-boot-task] /'
        gbrain apply-migrations --yes 2>&1 | sed 's/^/[gbrain-boot-task] /'
        btlog "selfheal-sync: recorded sync failures (the file(s) blocking ingestion):"
        if [ -f "$HOME/.gbrain/sync-failures.jsonl" ]; then
          sed 's/^/[gbrain-boot-task] FAILED-FILE: /' "$HOME/.gbrain/sync-failures.jsonl"
        else
          btlog "  (no ~/.gbrain/sync-failures.jsonl yet)"
        fi
        btlog "selfheal-sync: advancing sync bookmark past the blocked file(s)"
        gbrain sync --skip-failed 2>&1 | sed 's/^/[gbrain-boot-task] /'
        gbrain embed --stale 2>&1 | sed 's/^/[gbrain-boot-task] /'
        gbrain doctor 2>&1 | grep -iE '\[FAIL\]|\[WARN\]|brain_score|Overall health' | sed 's/^/[gbrain-boot-task] /'
        btlog "selfheal-sync: DONE — reset GBRAIN_BOOT_TASK to post-upgrade now"
        ;;
      selfheal-full)
        # ONE-SHOT comprehensive recovery (reset GBRAIN_BOOT_TASK to post-upgrade
        # after). Fast, idempotent fixes run inline; the slow backfills (extract /
        # reindex) are BACKGROUNDED so they can't blow Railway's ~5-min healthcheck
        # window — they keep running after the gateway comes up (log:
        # /tmp/gbrain-backfill.log). Do NOT redeploy until the backfills finish, or
        # they restart from scratch (both are idempotent, so a restart is safe).
        #
        # 1. Route the subagent tier to OpenRouter (no Anthropic dependency). `auto`
        #    can land on weak/no-tool models and never caches; pin a capable one.
        btlog "selfheal-full: set models.tier.subagent to openrouter:auto (dynamic)"
        gbrain config set models.tier.subagent openrouter:auto 2>&1 | sed 's/^/[gbrain-boot-task] /'
        # 2. Re-create the schema the ledger reports as done but whose objects are
        #    missing ("falsely up-to-date": config.version >= 80 so the version-gated
        #    runner applies nothing, yet takes.resolved_quality / drift_decisions are
        #    absent). `apply-migrations --force-retry <int>` is a SILENT NO-OP here:
        #    that flag searches the SEMVER orchestrator registry, not the integer
        #    schema-migration registry, so "43"/"51" match nothing and exit success.
        #    --force-schema gates on config.version (already advanced) → "Applied 0".
        #    The only real lever is the idempotent DDL itself, applied directly.
        #    This is the FULL v43 (takes_resolved_quality_and_drift_decisions) +
        #    v80 (takes_unresolvable_quality) postgres block from gbrain migrate.ts,
        #    copied verbatim — every statement is IF-NOT-EXISTS / DROP-IF-EXISTS, so
        #    a re-run (or running when already healed) is a safe no-op. RLS on
        #    drift_decisions self-guards on rolbypassrls (Supabase grants none → it
        #    skips the ENABLE RLS, matching gbrain's own behavior; the boot-task RLS
        #    sweep above then protects the table table-by-table). (Quoted heredoc so
        #    the bun snippet is taken literally — no shell expansion of $ / backticks.)
        btlog "selfheal-full: applying full idempotent v43 + v80 DDL (resolved_quality + drift_decisions + unresolvable widen)"
        if [ -n "${DATABASE_URL}" ]; then
          cat > /tmp/_gbrain_v43_v80.ts <<'V43EOF'
const { SQL } = require("bun");
const sql = new SQL(process.env.DATABASE_URL);
// --- v43: takes_resolved_quality_and_drift_decisions (postgres variant, verbatim) ---
await sql.unsafe(`
  ALTER TABLE takes
    ADD COLUMN IF NOT EXISTS resolved_quality TEXT
      CHECK (resolved_quality IS NULL OR resolved_quality IN ('correct','incorrect','partial'));

  UPDATE takes
  SET resolved_quality = CASE resolved_outcome
    WHEN true  THEN 'correct'
    WHEN false THEN 'incorrect'
  END
  WHERE resolved_outcome IS NOT NULL AND resolved_quality IS NULL;

  ALTER TABLE takes DROP CONSTRAINT IF EXISTS takes_resolution_consistency;
  ALTER TABLE takes ADD CONSTRAINT takes_resolution_consistency CHECK (
    (resolved_quality IS NULL     AND resolved_outcome IS NULL)
    OR (resolved_quality = 'correct'   AND resolved_outcome = true)
    OR (resolved_quality = 'incorrect' AND resolved_outcome = false)
    OR (resolved_quality = 'partial'   AND resolved_outcome IS NULL)
  );

  CREATE INDEX IF NOT EXISTS idx_takes_scorecard
    ON takes (holder, kind, resolved_quality)
    WHERE resolved_quality IS NOT NULL;

  CREATE TABLE IF NOT EXISTS drift_decisions (
    id                  BIGSERIAL   PRIMARY KEY,
    take_id             BIGINT      NOT NULL REFERENCES takes(id) ON DELETE CASCADE,
    page_id             INTEGER     NOT NULL,
    row_num             INTEGER     NOT NULL,
    recommended_weight  REAL        NOT NULL CHECK (recommended_weight >= 0 AND recommended_weight <= 1),
    reasoning           TEXT,
    decided_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_at          TIMESTAMPTZ,
    applied_by          TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_drift_decisions_take       ON drift_decisions(take_id);
  CREATE INDEX IF NOT EXISTS idx_drift_decisions_decided_at ON drift_decisions(decided_at DESC);

  DO $$
  DECLARE
    has_bypass BOOLEAN;
  BEGIN
    SELECT rolbypassrls INTO has_bypass FROM pg_roles WHERE rolname = current_user;
    IF has_bypass THEN
      ALTER TABLE drift_decisions ENABLE ROW LEVEL SECURITY;
    END IF;
  END $$;
`);
console.log("v43 DDL applied (resolved_quality + drift_decisions)");
// --- v80: takes_unresolvable_quality_v0_37_2_0 (verbatim) ---
await sql.unsafe(`
  ALTER TABLE takes DROP CONSTRAINT IF EXISTS takes_resolved_quality_check;
  ALTER TABLE takes DROP CONSTRAINT IF EXISTS takes_resolved_quality_values;
  ALTER TABLE takes ADD CONSTRAINT takes_resolved_quality_values CHECK (
    resolved_quality IS NULL
    OR resolved_quality IN ('correct', 'incorrect', 'partial', 'unresolvable')
  );

  ALTER TABLE takes DROP CONSTRAINT IF EXISTS takes_resolution_consistency;
  ALTER TABLE takes ADD CONSTRAINT takes_resolution_consistency CHECK (
    (resolved_quality IS NULL             AND resolved_outcome IS NULL)
    OR (resolved_quality = 'correct'      AND resolved_outcome = true)
    OR (resolved_quality = 'incorrect'    AND resolved_outcome = false)
    OR (resolved_quality = 'partial'      AND resolved_outcome IS NULL)
    OR (resolved_quality = 'unresolvable' AND resolved_outcome IS NULL)
  );
`);
console.log("v80 DDL applied (unresolvable widen)");
await sql.end();
V43EOF
          bun /tmp/_gbrain_v43_v80.ts 2>&1 | sed 's/^/[gbrain-boot-task] /'
        else
          btlog "selfheal-full: DATABASE_URL unset — skipping v43/v80 DDL"
        fi
        # 3. Acknowledge the now-stale recorded sync failure (8090, already fixed).
        gbrain sync --skip-failed 2>&1 | sed 's/^/[gbrain-boot-task] /'
        gbrain doctor 2>&1 | grep -iE '\[FAIL\]|\[WARN\]|brain_score|Overall health' | sed 's/^/[gbrain-boot-task] /'
        # 4. Background the heavy backfills: extract --stale (un-extracted edges →
        #    graph/find_experts quality) + reindex --markdown (contextual-retrieval).
        btlog "selfheal-full: backgrounding extract --stale + reindex --markdown (-> /tmp/gbrain-backfill.log)"
        nohup sh -c 'gbrain extract --stale 2>&1; gbrain reindex --markdown 2>&1' > /tmp/gbrain-backfill.log 2>&1 &
        btlog "selfheal-full: DONE — reset GBRAIN_BOOT_TASK to post-upgrade after backfills finish"
        ;;
      self-heal)
        # Escalating self-heal ladder (in-place heals 1–6: migrations, RLS sweep,
        # wedged-queue recover, re-apply core patches, embed/extract catch-up,
        # verify+doctor gate). Runs the thin wrapper installed at /data/scripts/
        # (forwards to _ops/scripts/self-heal.sh in the pulled workspace) so it
        # tracks the latest pushed script without a rebuild. Idempotent and
        # strictly non-fatal. SELF_REBUILD_ENABLED is deliberately LEFT UNSET so
        # step 7 (Railway self-rebuild) stays OFF by default — never arm
        # auto-rebuild from boot. Same script is driven on a cron tick.
        btlog "self-heal: running /data/scripts/self-heal.sh (self-rebuild OFF — SELF_REBUILD_ENABLED unset)"
        bash /data/scripts/self-heal.sh 2>&1 | sed 's/^/[gbrain-boot-task] /'
        btlog "self-heal: exit=${PIPESTATUS[0]}"
        ;;
      *)
        btlog "unknown task ${GBRAIN_BOOT_TASK} (known: post-upgrade|doctor|verify|selfheal-sync|selfheal-full|self-heal) — skipping"
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

    # --- DURABLE gateway-loop pin (FIX-NA-1 / FIX-NA-2 defense in depth) -------
    # Runs on EVERY container start, BEFORE the autopilot daemon (and thus the
    # Minions worker) launches, so the subagent loop is wired to route through
    # the gateway -> resolveRecipe -> openrouter:auto and NEVER touches the legacy
    # native `anthropic:` path. The subagent handler reads agent.use_gateway_loop
    # via engine.getConfig (the DB-backed store), so `gbrain config set` is the
    # correct store to write. Pinning it here makes gateway-loop routing durable:
    # a config reset / DB-restore / fresh volume cannot silently re-expose the
    # native path (which crash-looped the worker and wedged the default queue for
    # ~3h on 2026-06-08). Idempotent (set-to-same-value is a no-op) and strictly
    # non-fatal (`|| true`) — a config hiccup must never block the gateway.
    # --force is REQUIRED: agent.use_gateway_loop is a forward-compat key that
    # gbrain does not recognize in this version, so a plain `config set` rejects
    # it as "Unknown config key" and no-ops (gbrain's own message: "If this is
    # intentional ... re-run with --force"). --force writes it anyway so the
    # value is durably persisted for whenever the subagent handler reads it.
    echo "[gbrain-boot] pinning agent.use_gateway_loop=true --force (durable gateway-loop routing)"
    gbrain config set agent.use_gateway_loop true --force 2>&1 | sed 's/^/[gbrain-boot] /' || true

    # --- clear stale supervisor crash / gave-up record (boot-task health) ------
    # gbrain has NO `supervisor-state.json`; the supervisor "gave up" / max_crashes
    # signal lives in a weekly-rotated JSONL audit trail at
    #   ${GBRAIN_AUDIT_DIR:-~/.gbrain/audit}/supervisor-YYYY-Www.jsonl
    # (src/core/minions/handlers/supervisor-audit.ts + src/core/audit/audit-writer.ts).
    # `gbrain doctor` / `gbrain jobs supervisor status` read current+previous ISO
    # week and FAIL on the latest `max_crashes_exceeded` crash event — so after the
    # FIX-NA-2 crash-loop, a FRESH healthy container keeps emitting a stale
    # `[FAIL] supervisor` line for up to two weeks, false-flagging boot-task health
    # purely on history. We prune ONLY the crash/gave-up rows (max_crashes_exceeded,
    # health_error, worker_spawn_failed, and worker_exited lines whose likely_cause
    # is not a clean exit) from the current + previous week files, preserving every
    # clean lifecycle row (started / worker_spawned / clean worker_exited / etc.) so
    # the verdict reflects the CURRENT run, not the resolved crash-loop. Runs before
    # the supervisor re-launches. Idempotent (re-run on already-clean files removes
    # nothing) and strictly non-fatal (`|| true`; missing files => no-op).
    echo "[gbrain-boot] pruning stale supervisor crash/gave-up rows from weekly audit (boot-task health)"
    if command -v bun >/dev/null 2>&1; then
      cat > /tmp/_gbrain_clear_supervisor_crashes.ts <<'SUPEOF'
import * as fs from 'node:fs';
import * as path from 'node:path';
// Mirror gbrain's audit-dir + ISO-week filename resolution exactly so we touch
// the SAME files doctor reads (src/core/audit/audit-writer.ts).
const auditDir = (process.env.GBRAIN_AUDIT_DIR && process.env.GBRAIN_AUDIT_DIR.trim())
  ? process.env.GBRAIN_AUDIT_DIR.trim()
  : path.join(process.env.HOME || '.', '.gbrain', 'audit');
function isoWeekFilename(prefix: string, now: Date): string {
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const dayNum = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - dayNum + 3);
  const isoYear = d.getUTCFullYear();
  const firstThursday = new Date(Date.UTC(isoYear, 0, 4));
  const ftDayNum = (firstThursday.getUTCDay() + 6) % 7;
  firstThursday.setUTCDate(firstThursday.getUTCDate() - ftDayNum + 3);
  const weekNum = Math.round((d.getTime() - firstThursday.getTime()) / (7 * 86400000)) + 1;
  return `${prefix}-${isoYear}-W${String(weekNum).padStart(2, '0')}.jsonl`;
}
// Clean-exit causes per supervisor-audit.ts CLEAN_EXIT_CAUSES — a worker_exited
// with one of these is NOT a crash and must be preserved.
const CLEAN = new Set(['clean_exit', 'graceful_shutdown', 'wedge_restart']);
const now = new Date();
const files = [isoWeekFilename('supervisor', now),
               isoWeekFilename('supervisor', new Date(now.getTime() - 7 * 86400000))];
let totalDropped = 0;
for (const fn of files) {
  const full = path.join(auditDir, fn);
  let raw: string;
  try { raw = fs.readFileSync(full, 'utf8'); } catch { continue; }
  const kept: string[] = [];
  let dropped = 0;
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    let obj: any;
    try { obj = JSON.parse(line); } catch { kept.push(line); continue; } // keep unparseable verbatim
    const ev = obj && obj.event;
    let isCrash = false;
    if (ev === 'max_crashes_exceeded' || ev === 'health_error' || ev === 'worker_spawn_failed') {
      isCrash = true;
    } else if (ev === 'worker_exited') {
      const cause = obj.likely_cause as string | undefined;
      if (cause === undefined) isCrash = (obj.code !== 0); // legacy fallback (matches isCrashExit)
      else isCrash = !CLEAN.has(cause);
    }
    if (isCrash) dropped++; else kept.push(line);
  }
  if (dropped > 0) {
    fs.writeFileSync(full, kept.length ? kept.join('\n') + '\n' : '', { encoding: 'utf8' });
    totalDropped += dropped;
    console.log(`pruned ${dropped} crash/gave-up row(s) from ${fn}`);
  }
}
if (totalDropped === 0) console.log('no stale supervisor crash rows to prune (clean)');
SUPEOF
      GBRAIN_AUDIT_DIR="${GBRAIN_AUDIT_DIR}" bun /tmp/_gbrain_clear_supervisor_crashes.ts 2>&1 | sed 's/^/[gbrain-boot] /' || true
    else
      echo "[gbrain-boot] bun not on PATH; skipping supervisor crash-row prune (non-fatal)"
    fi

    # --- orphaned-supervisor-lock reclaim poller (Cause B: deploy-wedge) -------
    # CAUSE B. The Minions worker supervisor (`gbrain jobs supervisor`) is a
    # queue-scoped singleton guarded by ONE row in gbrain_cycle_locks
    # (id='gbrain-supervisor:default'): the holder refreshes ttl_expires_at +
    # last_refreshed_at every 60s, with a 5-min TTL. On a Railway redeploy the
    # OLD container is HARD-KILLED (SIGKILL, no graceful release) so its lock row
    # is left behind with a ttl_expires_at up to 5 min in the FUTURE. gbrain's
    # own acquire (tryAcquireDbLock in src/core/db-lock.ts) only steals via
    # ON CONFLICT when `ttl_expires_at < NOW() AND last_refreshed_at < NOW() -
    # stealGrace(~100s)`. The future-dated ttl_expires_at fails that gate, so the
    # NEW container's supervisor CANNOT steal the row for up to ~5 min: its single
    # acquire attempt returns null, MinionSupervisor.start() exits LOCK_HELD
    # ("Supervisor already running ... Exiting."), and the default queue WEDGES
    # (worker alive, 0 active, jobs unclaimed) until the TTL finally lapses. This
    # recurred on a deploy earlier today (job #2452 sat unclaimed).
    #
    # THE SAFE SIGNAL. gbrain's OWN liveness model (classifyHolderLiveness in
    # db-lock.ts) treats a CROSS-HOST holder that has stopped refreshing as dead
    # (process.kill is meaningless across hosts/containers). We mirror exactly
    # that: reclaim the lock ONLY when it is held by a DIFFERENT host AND has not
    # refreshed in > 120s. We bypass ONLY the over-conservative future-ttl gate;
    # we do NOT weaken the staleness signal.
    #   - DIFFERENT host: the holder is some OTHER container. Our own live
    #     supervisor (same hostname) is never matched, so we can't steal from
    #     ourselves.
    #   - > 120s since last refresh: the supervisor refreshes every 60s, and
    #     gbrain's steal-grace is ~100s (resolveStealGraceSeconds(5) = 2×60s).
    #     120s is past 2 refresh ticks AND past gbrain's own grace, so a
    #     genuinely-alive holder is never inside this window. During the Railway
    #     deploy OVERLAP the OLD container is STILL alive and refreshing
    #     (last_refreshed < 120s), so it is NOT reclaimed -> there is no risk of
    #     two live supervisors. Only a hard-killed old container, which by
    #     definition stops refreshing, ages past 120s and becomes reclaimable.
    # The DELETE touches ONLY the one 'gbrain-supervisor:default' row and is a
    # no-op every tick until the orphan is genuinely stale.
    #
    # WHY A BOUNDED BACKGROUND POLL, NOT A ONE-SHOT. At start.sh time during a
    # deploy the OLD container is typically STILL alive and refreshing, so a
    # one-shot reclaim would see last_refreshed < 120s and no-op, then the old
    # container dies a few seconds/minutes later and the orphan sits for the full
    # TTL — exactly the wedge. The poll has to OUTLIVE the overlap->old-death gap:
    # it re-checks every ~20s for up to ~12 min and reclaims the moment the old
    # holder crosses the 120s-stale line.
    #
    # SUPERVISOR NUDGE (see supervisor.ts MinionSupervisor.start): the supervisor
    # acquires the lock EXACTLY ONCE — on failure it `process.exit(LOCK_HELD)`
    # immediately, with NO retry timer. So the new container's supervisor that hit
    # the wedge has already GIVEN UP and exited; the DELETE alone frees the row but
    # nothing re-acquires it. We therefore nudge after the reclaim with
    # `gbrain jobs supervisor start --detach` — gbrain's own canonical re-launch
    # (doctor.ts remediation: "Restart with: gbrain jobs supervisor start
    # --detach"). It forks a detached supervisor that runs a fresh acquire against
    # the now-free row, and it is IDEMPOTENT: its O_CREAT|O_EXCL pidfile guard
    # makes a redundant launch a no-op ("Supervisor already running ... Exiting."),
    # which is the safe-by-construction message we observed. Strictly non-fatal.
    echo "[gbrain-reclaim] arming orphaned-supervisor-lock reclaim poller (Cause B deploy-wedge guard)"
    if command -v bun >/dev/null 2>&1 && [ -n "${DATABASE_URL}" ]; then
      # Quoted heredoc: the bun snippet is taken literally (no shell expansion of
      # $ / backticks). Hostname is read at RUNTIME via os.hostname() inside the
      # script — the SAME value gbrain writes to holder_host — so the cross-host
      # comparison is exact.
      cat > /tmp/_gbrain_reclaim_supervisor_lock.ts <<'RECLAIMEOF'
import { hostname } from 'node:os';
const { SQL } = require('bun');
const sql = new SQL(process.env.DATABASE_URL);
const me = hostname();
// LOAD-BEARING SAFETY CONTRACT — do NOT weaken this predicate. Reclaim ONLY a
// DIFFERENT-host holder whose refresh is older than 120s (past gbrain's ~100s
// steal-grace). Bypasses ONLY the future-ttl gate; touches ONLY this one row.
const rows = await sql.unsafe(
  `DELETE FROM gbrain_cycle_locks
    WHERE id = 'gbrain-supervisor:default'
      AND holder_host <> $1
      AND (last_refreshed_at IS NULL
           OR last_refreshed_at < NOW() - 120 * INTERVAL '1 second')
   RETURNING holder_pid, holder_host, last_refreshed_at`,
  [me],
);
await sql.end();
if (rows.length > 0) {
  const r = rows[0];
  console.log(`reclaimed orphaned supervisor lock from dead container: ` +
    `host=${r.holder_host} pid=${r.holder_pid} last_refresh=${r.last_refreshed_at} (this host=${me})`);
  process.exit(10); // distinct "reclaimed" signal for the bash poll
}
process.exit(0);
RECLAIMEOF
      # Bounded background poll: ~20s cadency for up to ~720s (12 min), wrapped in
      # `( set +e ... ) &` || true so it never blocks the gateway. On the FIRST
      # reclaim it nudges the supervisor and stops; otherwise it logs that the
      # poll finished clean and exits. Backgrounded BEFORE `gbrain autopilot
      # --install` / before `exec python /app/server.py` so it outlives the
      # deploy overlap->old-death gap.
      (
        set +e
        reclaim_deadline=$(( $(date +%s) + 720 ))
        while [ "$(date +%s)" -lt "${reclaim_deadline}" ]; do
          out="$(bun /tmp/_gbrain_reclaim_supervisor_lock.ts 2>&1)"; rc=$?
          if [ -n "${out}" ]; then echo "${out}" | sed 's/^/[gbrain-reclaim] /'; fi
          if [ "${rc}" -eq 10 ]; then
            echo "[gbrain-reclaim] orphan reclaimed — nudging a fresh supervisor (jobs supervisor start --detach)"
            gbrain jobs supervisor start --detach 2>&1 | sed 's/^/[gbrain-reclaim] /' || true
            break
          fi
          sleep 20
        done
        echo "[gbrain-reclaim] reclaim poll finished"
      ) &
      echo "[gbrain-reclaim] reclaim poller backgrounded (pid $!; ~20s ticks for up to ~12 min)"
    else
      echo "[gbrain-reclaim] bun not on PATH or DATABASE_URL empty; skipping reclaim poller (non-fatal)"
    fi

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
