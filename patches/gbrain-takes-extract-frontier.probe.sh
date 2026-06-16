#!/usr/bin/env bash
# still_needed_probe FIX-TKF-1. Run against the VANILLA candidate tree.
# 0 = STILL NEEDED   1 = OBSOLETE   2 = UNKNOWN
set -uo pipefail
GBRAIN_SRC=""
for d in "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
[ -z "$GBRAIN_SRC" ] && { echo "[tkf-1-probe] UNKNOWN: gbrain src not found." >&2; exit 2; }
C="$GBRAIN_SRC/core/extract-takes-from-pages.ts"
[ -f "$C" ] || { echo "[tkf-1-probe] UNKNOWN: extract-takes-from-pages.ts not found — extractor restructured; manual review." >&2; exit 2; }

# Already-has-takes / cursor frontier present upstream?
if grep -qiE "NOT EXISTS \(SELECT 1 FROM takes|tk\.page_id = pages\.id|updated_at > \\\$?\{?cursor" "$C"; then
  echo "[tkf-1-probe] OBSOLETE: extractor already has an already-has-takes / cursor frontier upstream; retire FIX-TKF-1."
  exit 1
fi
# Vanilla query still selects by length>200 + ORDER BY updated_at with no frontier?
if grep -qF "length(COALESCE(compiled_truth, '')) > 200" "$C"; then
  echo "[tkf-1-probe] STILL NEEDED: extractor query has no already-has-takes frontier — re-runs re-LLM the same pages."
  exit 0
fi
echo "[tkf-1-probe] UNKNOWN: query shape changed — manual review." >&2
exit 2
