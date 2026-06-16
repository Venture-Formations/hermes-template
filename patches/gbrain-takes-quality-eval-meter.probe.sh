#!/usr/bin/env bash
# still_needed_probe FIX-TQM-1. Run against the VANILLA candidate tree.
# 0 = STILL NEEDED   1 = OBSOLETE   2 = UNKNOWN
set -uo pipefail
GBRAIN_SRC=""
for d in "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
[ -z "$GBRAIN_SRC" ] && { echo "[tqm-1-probe] UNKNOWN: gbrain src not found." >&2; exit 2; }
R="$GBRAIN_SRC/core/takes-quality-eval/runner.ts"
[ -f "$R" ] || { echo "[tqm-1-probe] UNKNOWN: runner.ts not found — eval restructured; manual review." >&2; exit 2; }

panel_bad=0; filter_missing=0
grep -qF "'openai:gpt-4o'," "$R" || grep -qF "'google:gemini-1.5-pro'," "$R" && panel_bad=1
# active filter present in the default-branch sampler?
grep -qE "JOIN pages p ON p.id = t.page_id WHERE t.active|WHERE t\.active" "$R" || filter_missing=1

if [ "$panel_bad" = "1" ] || [ "$filter_missing" = "1" ]; then
  echo "[tqm-1-probe] STILL NEEDED: native default panel present=$panel_bad / eval active-filter missing=$filter_missing — bare eval still INCONCLUSIVE/native-billing and/or scores struck rows."
  exit 0
fi
echo "[tqm-1-probe] OBSOLETE: default panel is non-native AND the eval sampler filters active — upstream fixed both; retire FIX-TQM-1."
exit 1
