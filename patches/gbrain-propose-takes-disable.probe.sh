#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-propose-takes-disable.probe.sh   (still_needed_probe for FIX-PT-2)
#
# Answers, per upgrade, the ONE question the operator asked: "did this gbrain
# version address the underlying issue, so the patch can be retired?" — for THIS
# patch specifically. Run by the WS4 CI dry-run against the VANILLA (un-patched)
# candidate tree, and by verify-upgrade.sh on-container.
#
# The underlying issue FIX-PT-2 exists for: the dream/autopilot cycle's
# `propose_takes` phase runs EVERY tick with NO enable gate (unlike
# cycle.skillopt.enabled / cycle.conversation_facts_backfill.enabled), and is
# upstream-broken — no consumer/review CLI (#1467), no negative-result cache so
# it re-LLMs every zero-take page (#2106). The patch is OBSOLETE the day gbrain
# adds its OWN cycle.propose_takes.enabled gate (or otherwise makes the phase
# opt-in / config-gated) upstream.
#
# Exit codes (the harness contract for every *.probe.sh):
#   0 = STILL NEEDED  — the issue reproduces on this ref; keep the patch
#   1 = OBSOLETE      — upstream addressed it; recommend retirement (recommend-only)
#   2 = UNKNOWN       — could not determine (tree/anchor gone); escalate for manual review
# ---------------------------------------------------------------------------
set -uo pipefail

GBRAIN_SRC=""
for d in \
  "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[pt2-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

CYCLE="$GBRAIN_SRC/core/cycle.ts"
PROPOSE="$GBRAIN_SRC/core/cycle/propose-takes.ts"

if [ ! -f "$CYCLE" ]; then
  echo "[pt2-probe] UNKNOWN: core/cycle.ts not found — tree restructured; manual review." >&2
  exit 2
fi

# Anchor: the propose_takes RUN-block opener the patch wraps. If gone, the cycle
# was refactored — escalate (the patch self-audit would fail the build).
HAS_ANCHOR=$(grep -F "if (phases.includes('propose_takes')) {" "$CYCLE" 2>/dev/null | wc -l | tr -d ' ')
if [ "$HAS_ANCHOR" -eq 0 ]; then
  echo "[pt2-probe] UNKNOWN: propose_takes phase anchor gone — cycle.ts refactored; manual review." >&2
  exit 2
fi

# Upstream-fix signal: an UPSTREAM cycle.propose_takes.enabled gate that is NOT
# ours (i.e. gbrain solved it natively). Look for the literal config key in
# cycle.ts OR core/cycle/propose-takes.ts, OUTSIDE our VF-FIX-PT-2 sentinel.
UPSTREAM_GATE=0
for f in "$CYCLE" "$PROPOSE"; do
  [ -f "$f" ] || continue
  if grep -qF 'cycle.propose_takes.enabled' "$f" 2>/dev/null && ! grep -qF 'VF-FIX-PT-2' "$f" 2>/dev/null; then
    UPSTREAM_GATE=1
  fi
done

echo "[pt2-probe] propose_takes anchor present:$HAS_ANCHOR ; upstream propose_takes.enabled gate present:$UPSTREAM_GATE"

if [ "$UPSTREAM_GATE" -eq 1 ]; then
  echo "[pt2-probe] OBSOLETE: gbrain appears to gate the propose_takes phase via cycle.propose_takes.enabled upstream — review and retire FIX-PT-2 (keep the operator config)."
  exit 1
fi
echo "[pt2-probe] STILL NEEDED: propose_takes phase runs ungated (no upstream cycle.propose_takes.enabled gate)."
exit 0
