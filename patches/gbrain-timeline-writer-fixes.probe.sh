#!/usr/bin/env bash
# still_needed_probe for FIX-TL-1 + TL-2 + TL-4 (gbrain-timeline-writer-fixes).
# Answers per upgrade: do the three timeline-writer defects still reproduce?
#   TL-1: enrichEntity stamps timeline date from new Date() (not published_at/captured_at)
#   TL-2: check-backlinks fix writes a DATED '- **DATE** | Referenced in [...]' line
#   TL-4: fixBacklinkGaps inserts into ## Timeline ('// Insert into Timeline section')
# If ALL three are fixed upstream, retire the patch; partial deprecation is the
# operator's call. Conservative: STILL-NEEDED if ANY defect reproduces.
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
  echo "[tl-writer-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi
ENRICH="$GBRAIN_SRC/core/enrichment-service.ts"
BL="$GBRAIN_SRC/commands/backlinks.ts"
[ -f "$ENRICH" ] || { echo "[tl-writer-probe] UNKNOWN: core/enrichment-service.ts not found"; exit 2; }
[ -f "$BL" ] || { echo "[tl-writer-probe] UNKNOWN: commands/backlinks.ts not found"; exit 2; }

# TL-1 defect: the addTimelineEntry date field still uses new Date() (and not our sentinel).
TL1=0
if grep -qF "date: new Date().toISOString().split('T')[0] ?? '','" "$ENRICH" 2>/dev/null \
   || grep -qF "date: new Date().toISOString().split('T')[0] ?? ''," "$ENRICH" 2>/dev/null; then
  if ! grep -qF 'FIX-TL-1-WRITER' "$ENRICH" 2>/dev/null; then TL1=1; fi
fi

# TL-2 defect: buildBacklinkEntry still returns a DATED 'Referenced in [...]' line.
TL2=0
if grep -qF 'Referenced in [' "$BL" 2>/dev/null && grep -qF '**${date}**' "$BL" 2>/dev/null; then
  if ! grep -qF 'FIX-TL-2-WRITER' "$BL" 2>/dev/null; then TL2=1; fi
fi

# TL-4 defect: fixBacklinkGaps still inserts into ## Timeline (anchor comment present, no sort sentinel).
TL4=0
if grep -qF '// Insert into Timeline section' "$BL" 2>/dev/null; then
  if ! grep -qF 'FIX-TL-4-WRITER' "$BL" 2>/dev/null; then TL4=1; fi
fi

echo "[tl-writer-probe] TL-1(new Date timeline):$TL1 TL-2(dated Referenced-in):$TL2 TL-4(insert-into-Timeline):$TL4"

# If we couldn't observe ANY of the three defect anchors AND our sentinels are
# absent, the writer was refactored beyond recognition — escalate.
if [ "$TL1" -eq 0 ] && [ "$TL2" -eq 0 ] && [ "$TL4" -eq 0 ]; then
  if ! grep -qF 'FIX-TL-1-WRITER' "$ENRICH" 2>/dev/null \
     && ! grep -qF 'FIX-TL-2-WRITER' "$BL" 2>/dev/null \
     && ! grep -qF 'FIX-TL-4-WRITER' "$BL" 2>/dev/null \
     && ! grep -qF "date: new Date().toISOString().split('T')[0]" "$ENRICH" 2>/dev/null \
     && ! grep -qF '// Insert into Timeline section' "$BL" 2>/dev/null; then
    echo "[tl-writer-probe] OBSOLETE: none of the three timeline-writer defect shapes (new Date timeline / dated Referenced-in / insert-into-Timeline) are present upstream — review and retire (or partially deprecate) the patch."
    exit 1
  fi
fi

if [ "$TL1" -ge 1 ] || [ "$TL2" -ge 1 ] || [ "$TL4" -ge 1 ]; then
  echo "[tl-writer-probe] STILL NEEDED: at least one timeline-writer defect reproduces (TL-1/$TL1 TL-2/$TL2 TL-4/$TL4)."
  exit 0
fi
echo "[tl-writer-probe] STILL NEEDED (conservative): defect anchors ambiguous but not confirmed fixed; keep the patch and review manually."
exit 0
