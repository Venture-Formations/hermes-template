#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-no-anthropic-reroute.probe.sh   (still_needed_probe for FIX-NA-1)
#
# Answers, per upgrade, the ONE question the operator asked: "did this gbrain
# version address the underlying issue, so the patch can be retired?" — for THIS
# patch specifically. Run by the WS4 CI dry-run against the VANILLA (un-patched)
# candidate tree, and by verify-upgrade.sh on-container.
#
# The underlying issue FIX-NA-1 exists for: gbrain hardcodes native `anthropic:`
# model DEFAULTS at many touchpoints with no global config knob, so on a no-key
# deployment they throw and are swallowed → silent 0 facts. The patch is OBSOLETE
# the day gbrain stops hardcoding native-anthropic defaults (goes provider-
# agnostic / fully config-driven) OR resolveRecipe gains its own no-key reroute.
#
# Exit codes (the harness contract for every *.probe.sh):
#   0 = STILL NEEDED  — the issue reproduces on this ref; keep the patch
#   1 = OBSOLETE      — upstream addressed it; recommend retirement (recommend-only)
#   2 = UNKNOWN       — could not determine; escalate for manual review
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
  echo "[na-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

RESOLVER="$GBRAIN_SRC/core/ai/model-resolver.ts"

# Signal A: native `anthropic:claude-*` model DEFAULTS still hardcoded across the
# tree (excluding the recipe definition + pricing tables, which are inert data).
DEFAULTS=$(grep -rnE "'anthropic:claude-[a-z0-9.-]+'" --include='*.ts' "$GBRAIN_SRC" 2>/dev/null \
            | grep -vE '/ai/recipes/|pricing' | wc -l | tr -d ' ')

# Signal B: an UPSTREAM no-key reroute/guard in resolveRecipe that is NOT ours
# (i.e. gbrain solved it natively). Heuristic: ANTHROPIC_API_KEY referenced in
# the resolver outside our VF-FIX-NA-1 block.
UPSTREAM_GUARD=0
if [ -f "$RESOLVER" ]; then
  if grep -q 'ANTHROPIC_API_KEY' "$RESOLVER" 2>/dev/null && ! grep -q 'VF-FIX-NA-1' "$RESOLVER" 2>/dev/null; then
    UPSTREAM_GUARD=1
  fi
fi

echo "[na-probe] native-anthropic defaults still hardcoded: $DEFAULTS ; upstream no-key guard present: $UPSTREAM_GUARD"

if [ "$UPSTREAM_GUARD" -eq 1 ]; then
  echo "[na-probe] OBSOLETE: resolveRecipe appears to guard the no-ANTHROPIC_API_KEY case upstream — review and retire FIX-NA-1."
  exit 1
fi
if [ "$DEFAULTS" -eq 0 ]; then
  echo "[na-probe] OBSOLETE: gbrain no longer hardcodes native anthropic:claude-* defaults — review and retire FIX-NA-1."
  exit 1
fi
echo "[na-probe] STILL NEEDED: $DEFAULTS native anthropic:claude-* defaults remain with no upstream no-key guard."
exit 0
