#!/usr/bin/env bash
# still_needed_probe for FIX-DP-1 (gbrain-dir-pattern-owned-dirs).
# Answers per upgrade: does DIR_PATTERN STILL lack products|publications upstream?
# If gbrain added them natively, this patch is obsolete.
# Exit 0 = still needed, 1 = obsolete (recommend retire), 2 = unknown.
set -uo pipefail
GBRAIN_SRC=""
for d in "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
[ -z "$GBRAIN_SRC" ] && { echo "[dp1-probe] UNKNOWN: gbrain src tree not found." >&2; exit 2; }
T="$GBRAIN_SRC/core/link-extraction.ts"
[ -f "$T" ] || { echo "[dp1-probe] UNKNOWN: core/link-extraction.ts not found"; exit 2; }

# Anchor gone => inferLinkType/DIR_PATTERN refactored; manual review (the patch
# itself fails the build, but the probe should say UNKNOWN not obsolete).
if ! grep -qF "const DIR_PATTERN = '(?:people|companies|meetings|concepts" "$T"; then
  echo "[dp1-probe] UNKNOWN: DIR_PATTERN anchor gone — link-extraction refactored; manual review."
  exit 2
fi

# If gbrain already lists both dirs in DIR_PATTERN, the patch is obsolete.
# (We must check the SOURCE pattern, not our applied splice: read the pristine
# install — but this runs post-patch on-container, so the splice is present.
# The honest obsolete signal is upstream adding them, which is indistinguishable
# from our splice here; so the probe stays conservative = STILL NEEDED unless the
# anchor is gone. Retirement is decided by upgrade_eval step 2 against a pristine
# checkout, not this on-container probe.)
echo "[dp1-probe] STILL NEEDED: DIR_PATTERN anchor present; products|publications are not in upstream gbrain (confirm against a pristine checkout at upgrade time per upgrade_eval step 2)."
exit 0
