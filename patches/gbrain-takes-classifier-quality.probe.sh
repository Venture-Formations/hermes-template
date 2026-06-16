#!/usr/bin/env bash
# still_needed_probe FIX-TQC-1. Run against the VANILLA candidate tree.
# 0 = STILL NEEDED   1 = OBSOLETE   2 = UNKNOWN
set -uo pipefail
GBRAIN_SRC=""
for d in "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
[ -z "$GBRAIN_SRC" ] && { echo "[tqc-1-probe] UNKNOWN: gbrain src not found." >&2; exit 2; }
C="$GBRAIN_SRC/core/extract-takes-from-pages.ts"
[ -f "$C" ] || { echo "[tqc-1-probe] UNKNOWN: extract-takes-from-pages.ts not found — extractor restructured; manual review." >&2; exit 2; }

# Vanilla weak prompt markers: the bare Skip line + no weight-magnitude guidance.
if grep -qF "Skip pure narrative, questions, definitions, or pure quotes from others." "$C" && ! grep -qF "Weight rules (round to the 0.05 grid" "$C"; then
  echo "[tqc-1-probe] STILL NEEDED: CLASSIFIER_SYSTEM still has the bare Skip line and no 0.05-grid weight rules — kind/weight/signal guidance absent."
  exit 0
fi
if grep -qF "choose CONSERVATIVELY" "$C" || grep -qF "low-signal metadata" "$C"; then
  echo "[tqc-1-probe] OBSOLETE: CLASSIFIER_SYSTEM already carries kind-conservatism / named-trivia guidance upstream; retire FIX-TQC-1."
  exit 1
fi
echo "[tqc-1-probe] UNKNOWN: prompt shape changed (neither bare-skip nor our markers) — manual review." >&2
exit 2
