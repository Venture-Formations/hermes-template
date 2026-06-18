#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-cycle-abort-signal.sh   (VF FIX-CYCLE-ABORT-1)
#
# WHY THIS EXISTS
# A timed-out autopilot-cycle job cannot be killed by the Minions worker: on the
# per-job timeout the worker calls `abort.abort('timeout')`, waits 30s, then
# force-evicts the job from its in-memory inFlight set and logs
#   "did not exit within 30s of abort … The handler is still running".
# It holds NO handle to the cycle DB lock. The still-running handler is inside
# `runCycle`, which holds the per-source cycle lock until its `finally` releases
# it (cycle.ts). So a zombie handler holds the lock indefinitely and every
# subsequent cycle job starves → the `default` queue wedges until a human
# restarts the worker process. (Root-caused 2026-06-18 by a multi-agent review;
# the live incident: cycle jobs 3899/3900/3902/3907/3909 all hit the 600s timeout
# and zombie'd, the backlog grew unbounded, manual worker restarts were required.)
#
# THE UNBOUNDED CLASS. Five ALL_PHASES phases enter their LLM loop without the
# job's AbortSignal. Three (propose_takes/grade_takes/calibration_profile) never
# refresh the lock, so the 5-min TTL lapses, ages past the ~100s steal-grace, and
# the next cycle steals the lock — painful but SELF-HEALING (~5-7min). The other
# two — extract_atoms + synthesize_concepts — REFRESH the lock every 30s via
# `buildYieldDuringPhase` (maybeYield), so the steal-grace NEVER fires: a zombie
# spinning here holds the lock until its full page budget exhausts, which on a
# large brain far exceeds the job cadence. THAT is the restart-required incident.
# This patch fixes the two UNBOUNDED phases (the self-healing trio + two latent
# gateway sites — expandQuery/generateOcrText — are a tracked follow-up, and the
# start.sh worker-restart backstop covers every phase as a safety net).
#
# WHAT IT DOES (a direct continuation of the merged #1972 `consolidate.ts`
# cooperative-abort idiom — cycle.ts already threads `signal: opts.signal` into
# consolidate; these two phases were never given the same treatment):
#   1. cycle.ts — thread `signal: opts.signal` into the runPhaseExtractAtoms +
#      runPhaseSynthesizeConcepts dispatch opts.
#   2. extract-atoms.ts / synthesize-concepts.ts — add an optional `signal?:
#      AbortSignal` to their Opts, import `isAborted`, break at the TOP of the
#      OUTER work loop (page / concept boundary — NEVER the inner per-row putPage
#      loop, so a multi-row write is never torn), and forward `abortSignal:
#      opts.signal` into the per-item `chat()` call so the in-flight LLM fetch is
#      severed at once (the gateway's chat() honors opts.abortSignal).
# Page-boundary abort only → abort-then-retry under a 429 bench re-scans safely
# (extract_atoms is content_hash-keyed putPage; synth writes a DETERMINISTIC
# concept slug, idempotent on retry — both verified before shipping). No torn rows.
#
# Applied at Docker BUILD time after the gbrain install; re-applied on every
# GBRAIN_REF bump; idempotent; FAILS THE BUILD LOUDLY (old container keeps
# serving — no outage) if any anchor moved. See UPGRADING_GBRAIN.md +
# patches/gbrain-cycle-abort-signal.meta.yml.
# ---------------------------------------------------------------------------
set -euo pipefail

SENTINEL='VF (footgun fix): cooperative-abort signal threaded'

# Resolve the gbrain source tree across build + runtime layouts (test override first).
GBRAIN_SRC=""
for d in \
  "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -n "$d" ] && [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[cycle-abort] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

CYCLE="$GBRAIN_SRC/core/cycle.ts"
ATOMS="$GBRAIN_SRC/core/cycle/extract-atoms.ts"
SYNTH="$GBRAIN_SRC/core/cycle/synthesize-concepts.ts"
for f in "$CYCLE" "$ATOMS" "$SYNTH"; do
  [ -f "$f" ] || { echo "[cycle-abort] ERROR: target missing: $f" >&2; exit 1; }
done

# Idempotent: if the sentinel is already present, this image is already patched.
if grep -qF "$SENTINEL" "$ATOMS" 2>/dev/null; then
  echo "[cycle-abort] already applied (sentinel present) — no-op."
  exit 0
fi

# --- insert helper: literal-anchor (\Q\E), env-passed strings (no escaping) ----
# Inserts ADD immediately AFTER the FIRST literal occurrence of ANCHOR. Anchors
# are chosen UNIQUE per file so the first-match insert is unambiguous.
ins() {  # ins <file> <anchor> <addition>
  local file="$1" anchor="$2" add="$3"
  grep -qF "$anchor" "$file" || {
    echo "[cycle-abort] ERROR: anchor gone from $(basename "$file") — RE-POINT (see UPGRADING_GBRAIN.md):" >&2
    printf '%s\n' "$anchor" | head -3 >&2
    exit 1
  }
  ANCHOR="$anchor" ADD="$add" perl -0777 -i -pe 'BEGIN{$a=$ENV{ANCHOR};$b=$ENV{ADD}} s/\Q$a\E/$a$b/' "$file"
}

echo "[cycle-abort] preflight + apply against: $GBRAIN_SRC"

# ===== extract-atoms.ts =====
ins "$ATOMS" \
"import { chat as gatewayChat } from '../ai/gateway.ts';" \
"
import { isAborted } from '../abort-check.ts';"

ins "$ATOMS" \
"  yieldDuringPhase?: () => Promise<void>;" \
"
  /**
   * VF (footgun fix): cooperative-abort signal threaded from the job worker's
   * per-job-timeout. Checked at the top of the work loop so a timed-out cycle
   * exits at the next page boundary and releases the cycle lock, instead of
   * running on as a zombie that wedges the queue. Mirrors consolidate.ts (#1972).
   */
  signal?: AbortSignal;"

ins "$ATOMS" \
"  for (const item of work) {" \
"
    // VF (footgun fix): cooperative abort at the page boundary (mirrors
    // consolidate.ts #1972) — a per-job-timeout abort exits here, releasing
    // the cycle lock instead of grinding on as a queue-wedging zombie.
    if (isAborted(opts.signal)) break;"

ins "$ATOMS" \
"        maxTokens: 2000," \
"
        // VF (footgun fix): thread the abort signal so the in-flight LLM fetch
        // is severed the moment the job aborts (gateway honors opts.abortSignal)."$'\n'"        abortSignal: opts.signal,"

# ===== synthesize-concepts.ts =====
ins "$SYNTH" \
"import { chat as gatewayChat } from '../ai/gateway.ts';" \
"
import { isAborted } from '../abort-check.ts';"

ins "$SYNTH" \
"  yieldDuringPhase?: (() => Promise<void>) | undefined;" \
"
  /**
   * VF (footgun fix): cooperative-abort signal threaded from the job worker's
   * per-job-timeout. Checked at the top of the group loop so a timed-out cycle
   * exits at the next concept boundary and releases the cycle lock, instead of
   * running on as a zombie that wedges the queue. Mirrors consolidate.ts (#1972).
   */
  signal?: AbortSignal;"

ins "$SYNTH" \
"  for (const group of atomGroups) {" \
"
    // VF (footgun fix): cooperative abort at the concept boundary (mirrors
    // consolidate.ts #1972) — a per-job-timeout abort exits here, releasing
    // the cycle lock instead of grinding on as a queue-wedging zombie.
    if (isAborted(opts.signal)) break;"

ins "$SYNTH" \
"            maxTokens: 500," \
"
            // VF (footgun fix): thread the abort signal so the in-flight LLM
            // fetch is severed the moment the job aborts (gateway honors it)."$'\n'"            abortSignal: opts.signal,"

# ===== cycle.ts (two dispatch sites; anchors include the distinguishing
# preceding field so each first-match insert hits the right phase) =====
ins "$CYCLE" \
"          affectedSlugs: xaAffectedSlugs,
          // v0.41.19.0 (T3): closure refreshes cycle lock + fires outer hook.
          yieldDuringPhase: buildYieldDuringPhase(lock, opts.yieldDuringPhase)," \
"
          // VF (footgun fix): thread the job abort signal so a per-job-timeout
          // exits at the next page boundary and releases the cycle lock (this
          // refreshing phase is the UNBOUNDED wedge class — never lock-stealable).
          signal: opts.signal,"

ins "$CYCLE" \
"          dryRun,
          // v0.41.19.0 (T3): closure refreshes cycle lock + fires outer hook.
          yieldDuringPhase: buildYieldDuringPhase(lock, opts.yieldDuringPhase)," \
"
          // VF (footgun fix): thread the job abort signal (see extract_atoms) —
          // this refreshing phase is the other UNBOUNDED wedge class.
          signal: opts.signal,"

# --- POSTFLIGHT: assert every edit landed (fail the build if any didn't) ------
fail=0
grep -qF "import { isAborted } from '../abort-check.ts';" "$ATOMS" || { echo "[cycle-abort] POST: atoms isAborted import missing" >&2; fail=1; }
grep -qF "if (isAborted(opts.signal)) break;" "$ATOMS" || { echo "[cycle-abort] POST: atoms loop break missing" >&2; fail=1; }
grep -qF "abortSignal: opts.signal," "$ATOMS" || { echo "[cycle-abort] POST: atoms chat abortSignal missing" >&2; fail=1; }
grep -qF "if (isAborted(opts.signal)) break;" "$SYNTH" || { echo "[cycle-abort] POST: synth loop break missing" >&2; fail=1; }
grep -qF "abortSignal: opts.signal," "$SYNTH" || { echo "[cycle-abort] POST: synth chat abortSignal missing" >&2; fail=1; }
# cycle.ts must gain exactly TWO new `signal: opts.signal,` dispatch lines.
[ "$(grep -cF 'signal: opts.signal,' "$CYCLE")" -ge 2 ] || { echo "[cycle-abort] POST: cycle.ts dispatch signal lines < 2" >&2; fail=1; }
grep -qF "$SENTINEL" "$ATOMS" || { echo "[cycle-abort] POST: sentinel missing" >&2; fail=1; }
[ "$fail" = 0 ] || { echo "[cycle-abort] ERROR: postflight verification failed." >&2; exit 1; }

echo "[cycle-abort] OK — abort signal threaded into extract_atoms + synthesize_concepts (cooperative page/concept-boundary abort; FIX-CYCLE-ABORT-1)."
