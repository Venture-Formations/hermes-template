#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-schema-pack-bundled-ssot.probe.sh (still_needed_probe FIX-SP-SSOT)
# Run against the VANILLA candidate tree.
# Exit: 0=STILL NEEDED  1=OBSOLETE  2=UNKNOWN
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
[ -z "$GBRAIN_SRC" ] && { echo "[sp-ssot-probe] UNKNOWN: gbrain src not found." >&2; exit 2; }

MU="$GBRAIN_SRC/core/schema-pack/mutate.ts"
CS="$GBRAIN_SRC/commands/schema.ts"
[ -f "$MU" ] && [ -f "$CS" ] || { echo "[sp-ssot-probe] UNKNOWN: mutate.ts/schema.ts not found — restructured." >&2; exit 2; }

if [ -f "$GBRAIN_SRC/core/schema-pack/bundled.ts" ] && grep -qF 'VF-FIX-SP-SSOT' "$GBRAIN_SRC/core/schema-pack/bundled.ts" 2>/dev/null; then
  echo "[sp-ssot-probe] STILL NEEDED (patched tree: VF-FIX-SP-SSOT present — run against vanilla to test obsolescence)."
  exit 0
fi

# Bug signatures: the 3-entry mutate literal AND the gbrain-base-only special-case.
HAS_3LIST=0; grep -qF "new Set(['gbrain-base', 'gbrain-recommended', 'gbrain-base-v2'])" "$MU" && HAS_3LIST=1
HAS_BASEONLY=0; grep -qF "if (name === 'gbrain-base') {" "$CS" && HAS_BASEONLY=1

if [ "$HAS_3LIST" = "0" ] && [ "$HAS_BASEONLY" = "0" ]; then
  echo "[sp-ssot-probe] OBSOLETE? both the mutate 3-entry list AND the gbrain-base-only packPathByName special-case are gone — upstream may have consolidated. REVIEW and retire FIX-SP-SSOT."
  exit 1
fi
echo "[sp-ssot-probe] STILL NEEDED: disagreeing registries persist (3-list=$HAS_3LIST base-only-packPathByName=$HAS_BASEONLY)."
exit 0
