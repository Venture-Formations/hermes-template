#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-patterns-gateway-route.probe.sh  (still_needed_probe FIX-PG-1)
#
# Answers, per upgrade, "does the patterns phase STILL hard-gate on a literal
# native ANTHROPIC_API_KEY (no-op'ing the phase on a keyless gateway
# deployment), so this fix is still needed?" Run against the VANILLA
# (un-patched) candidate tree.
#
# STILL NEEDED while patterns.ts returns skipped('no_api_key') on a missing
# ANTHROPIC_API_KEY. OBSOLETE the day upstream drops that gate and routes the
# patterns subagent through the gateway unconditionally.
#
# Exit codes (harness contract):
#   0 = STILL NEEDED   1 = OBSOLETE   2 = UNKNOWN
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
  echo "[pg-1-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

TARGET="$GBRAIN_SRC/core/cycle/patterns.ts"
if [ ! -f "$TARGET" ]; then
  echo "[pg-1-probe] UNKNOWN: patterns.ts not found — phase restructured; manual review." >&2
  exit 2
fi

# The buggy gate verbatim. If patterns still no-ops on a missing native key, the
# phase stays dark on this keyless-gateway deployment.
if grep -qF "if (!process.env.ANTHROPIC_API_KEY) {" "$TARGET" \
   && grep -qF "return skipped('no_api_key'" "$TARGET"; then
  echo "[pg-1-probe] STILL NEEDED: patterns.ts still hard-gates on process.env.ANTHROPIC_API_KEY -> skipped('no_api_key'); on a keyless gateway deployment the patterns phase never runs."
  exit 0
fi

# The gate is gone. If patterns no longer references ANTHROPIC_API_KEY at all,
# upstream dropped the native-key gate -> retire FIX-PG-1.
if ! grep -qF "ANTHROPIC_API_KEY" "$TARGET"; then
  echo "[pg-1-probe] OBSOLETE: patterns.ts no longer references ANTHROPIC_API_KEY — upstream dropped the native-key gate; retire FIX-PG-1."
  exit 1
fi

echo "[pg-1-probe] UNKNOWN: ANTHROPIC_API_KEY still referenced in patterns.ts but not in the known skipped('no_api_key') gate shape — phase changed; manual review." >&2
exit 2
