#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-voice-gate-judge-prefix.probe.sh  (still_needed_probe FIX-VG-1)
#
# Answers, per upgrade, "does the calibration voice-gate judge STILL call its
# Haiku judge with a PREFIX-LESS model id ('claude-haiku-4-5') that throws in
# parseModelId before the FIX-NA-1 reroute, so this fix is still needed?" Run
# against the VANILLA (un-patched) candidate tree.
#
# STILL NEEDED while voice-gate.ts defaultJudge() uses the bare
# `model: 'claude-haiku-4-5',` id. OBSOLETE the day upstream prefixes it (or
# goes provider-agnostic so a bare id no longer throws).
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
  echo "[vg-1-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

TARGET="$GBRAIN_SRC/core/calibration/voice-gate.ts"
if [ ! -f "$TARGET" ]; then
  echo "[vg-1-probe] UNKNOWN: voice-gate.ts not found — phase restructured; manual review." >&2
  exit 2
fi

# Upstream already prefixes the judge id -> retire the patch.
if grep -qF "model: 'anthropic:claude-haiku-4-5'" "$TARGET"; then
  echo "[vg-1-probe] OBSOLETE: upstream already prefixes the voice-gate judge id (anthropic:claude-haiku-4-5); retire FIX-VG-1."
  exit 1
fi

# The bare id is still present -> the bug persists, patch still needed.
if grep -qF "model: 'claude-haiku-4-5'," "$TARGET"; then
  echo "[vg-1-probe] STILL NEEDED: voice-gate.ts defaultJudge still uses the bare id 'claude-haiku-4-5' which throws in parseModelId before the FIX-NA-1 reroute."
  exit 0
fi

echo "[vg-1-probe] UNKNOWN: neither bare nor anthropic-prefixed claude-haiku-4-5 literal found in voice-gate.ts — phase changed; manual review / re-point." >&2
exit 2
