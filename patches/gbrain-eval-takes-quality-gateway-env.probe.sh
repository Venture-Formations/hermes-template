#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-eval-takes-quality-gateway-env.probe.sh  (still_needed_probe FIX-TQ-1)
#
# Answers, per upgrade, "does eval-takes-quality.ts STILL configure the gateway
# by spreading process.env as top-level keys (leaving AIGatewayConfig.env
# undefined), so this fix is still needed?" Run against the VANILLA (un-patched)
# candidate tree.
#
# STILL NEEDED while the buggy `{ ...cfg, ...(process.env ...) }` spread is the
# configureGateway argument. OBSOLETE the day upstream nests env under `env:`
# (or otherwise gives configureGateway a defined env map) in this command.
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
  echo "[tq-1-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

CMD="$GBRAIN_SRC/commands/eval-takes-quality.ts"
if [ ! -f "$CMD" ]; then
  echo "[tq-1-probe] UNKNOWN: eval-takes-quality.ts not found — eval restructured; manual review." >&2
  exit 2
fi

# The buggy spread verbatim. If it's still the configureGateway argument, env is
# still undefined at gateway-config time → the eval still crashes INCONCLUSIVE.
if grep -qF "configureGateway({ ...cfg, ...(process.env as Record<string, string>) } as any);" "$CMD"; then
  echo "[tq-1-probe] STILL NEEDED: eval-takes-quality.ts still spreads process.env as top-level keys into configureGateway — AIGatewayConfig.env stays undefined → every model errors on env[k] → INCONCLUSIVE/exit-2."
  exit 0
fi

# The bug pattern is gone. If the command now passes a nested env map, upstream
# fixed it → retire FIX-TQ-1.
if grep -qF "configureGateway(" "$CMD" && grep -qE "env:\s*\{\s*\.\.\.process\.env" "$CMD"; then
  echo "[tq-1-probe] OBSOLETE: eval-takes-quality.ts now nests env under env: in configureGateway — upstream fixed it; retire FIX-TQ-1."
  exit 1
fi

echo "[tq-1-probe] UNKNOWN: neither the buggy spread nor a nested env: form found in configureGateway — command shape changed; manual review." >&2
exit 2
