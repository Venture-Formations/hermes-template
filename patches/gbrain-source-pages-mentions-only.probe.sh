#!/usr/bin/env bash
# still_needed_probe for FIX-TE-2 (gbrain-source-pages-mentions-only).
# Answers per upgrade: does inferLinkType still early-return 'mentions' for
# type:media but NOT for type:source (so source/web/article/feed captures still
# run the typed-verb regexes)? If gbrain gates source pages mentions-only
# natively (e.g. FIX-TE-1 lands), retire the patch. Conservative: prefer STILL-NEEDED.
# Exit 0 = still needed, 1 = obsolete (recommend retire), 2 = unknown.
set -uo pipefail
GBRAIN_SRC=""
for d in "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[te2-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi
T="$GBRAIN_SRC/core/link-extraction.ts"
[ -f "$T" ] || { echo "[te2-probe] UNKNOWN: core/link-extraction.ts not found"; exit 2; }

# Patch anchor: the existing media early-return guard. If gone, inferLinkType
# was refactored — escalate (the patch self-audit would fail the build).
HAS_MEDIA_GUARD=$(grep -cF "if (pageType === 'media') {" "$T" 2>/dev/null || echo 0)
if [ "$HAS_MEDIA_GUARD" -eq 0 ]; then
  echo "[te2-probe] UNKNOWN: media-guard anchor gone — inferLinkType refactored; manual review."
  exit 2
fi

# Upstream-fix signal: a native source-page guard exists OUTSIDE our FIX-TE-2
# block (gbrain now treats type:source as mentions-only on its own).
UPSTREAM=0
if ! grep -qF 'FIX-TE-2' "$T" 2>/dev/null; then
  if grep -qE "pageType[^)]*===[^)]*'source'|=== 'source'.*return 'mentions'" "$T" 2>/dev/null; then
    UPSTREAM=1
  fi
fi
echo "[te2-probe] media-guard:$HAS_MEDIA_GUARD upstream-source-guard:$UPSTREAM"

if [ "$UPSTREAM" -eq 1 ]; then
  echo "[te2-probe] OBSOLETE: inferLinkType appears to gate type:source pages mentions-only natively — review and retire FIX-TE-2."
  exit 1
fi
echo "[te2-probe] STILL NEEDED: media is mentions-only but type:source still runs the typed-verb regexes (no native source guard)."
exit 0
