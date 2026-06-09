#!/usr/bin/env bash
# still_needed_probe for FIX-TK-2 (gbrain-takes-notable-claims).
# Answers per upgrade: does the takes extractor still flush DB-only via
# addTakesBatch with NO markdown-first take fence-write and NO subject/speaker
# routing (and ALLOWED_PAGE_TYPES still excluding source/person/company)? If
# gbrain shipped a markdown-first take write path + subject routing upstream,
# retire the patch. Conservative: prefer STILL-NEEDED.
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
  echo "[tk2-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi
T="$GBRAIN_SRC/core/extract-takes-from-pages.ts"
[ -f "$T" ] || { echo "[tk2-probe] UNKNOWN: core/extract-takes-from-pages.ts not found"; exit 2; }

# Primary anchor: the DB-only flush site Part C replaces. If gone, the extractor
# was refactored — escalate (the patch self-audit would fail the build).
HAS_FLUSH=$(grep -cF "claimsExtracted += await engine.addTakesBatch(batch);" "$T" 2>/dev/null || echo 0)
if [ "$HAS_FLUSH" -eq 0 ]; then
  echo "[tk2-probe] UNKNOWN: addTakesBatch flush anchor gone — extract-takes-from-pages refactored; manual review."
  exit 2
fi

# Upstream-fix signal A: a native markdown-first take fence-write path exists
# (writeTakesToFence), OUTSIDE our FIX-TK-2 wiring sentinel.
UPSTREAM=0
if ! grep -qF 'FIX-TK-2' "$T" 2>/dev/null; then
  if grep -qiE "writeTakesToFence|takes/fence-write|writeTakeToFence" "$T" 2>/dev/null; then
    UPSTREAM=1
  fi
  # Upstream-fix signal B: ALLOWED_PAGE_TYPES already covers the alpha-bearing
  # types (source AND person AND company) natively.
  if grep -qE "ALLOWED_PAGE_TYPES" "$T" 2>/dev/null \
     && grep -qF "'source'" "$T" 2>/dev/null \
     && grep -qF "'person'" "$T" 2>/dev/null \
     && grep -qF "'company'" "$T" 2>/dev/null; then
    UPSTREAM=1
  fi
fi
echo "[tk2-probe] db-flush-anchor:$HAS_FLUSH upstream-markdown-first-or-widened-types:$UPSTREAM"

if [ "$UPSTREAM" -eq 1 ]; then
  echo "[tk2-probe] OBSOLETE: takes extractor appears to write markdown-first / cover source+person+company upstream — review and retire FIX-TK-2."
  exit 1
fi
echo "[tk2-probe] STILL NEEDED: takes extractor still flushes DB-only (addTakesBatch) with no markdown-first fence-write / subject routing."
exit 0
