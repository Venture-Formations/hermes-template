#!/usr/bin/env bash
# still_needed_probe for FIX-TL-3 (gbrain-timeline-bullet-hyphen-split).
# Answers per upgrade: does extractTimelineFromContent's Format-1 bullet regex
# still use a separator class that includes a BARE ASCII hyphen against a
# non-greedy source group (so it splits slugs on internal hyphens)? If gbrain
# fixed the parser upstream, retire the patch. Conservative: prefer STILL-NEEDED.
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
  echo "[tl3-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi
T="$GBRAIN_SRC/commands/extract.ts"
[ -f "$T" ] || { echo "[tl3-probe] UNKNOWN: commands/extract.ts not found"; exit 2; }

# Buggy literal (the defect): bare-hyphen separator class [—–-] after non-greedy (.+?).
BUGGY='/^-\s+\*\*(\d{4}-\d{2}-\d{2})\*\*\s*\|\s*(.+?)\s*[—–-]\s*(.+)$/gm'
# Our fixed literal (spaced em/en/double-dash, optional source group).
FIXED='(?:(.+?)\s+(?:—|–|--)\s+)?(.+)$/gm'

HAS_BUGGY=$(grep -cF "$BUGGY" "$T" 2>/dev/null || echo 0)
HAS_FIXED=$(grep -cF "$FIXED" "$T" 2>/dev/null || echo 0)
echo "[tl3-probe] buggy-bare-hyphen-regex:$HAS_BUGGY our-or-upstream-fixed-regex:$HAS_FIXED"

if [ "$HAS_BUGGY" -ge 1 ]; then
  echo "[tl3-probe] STILL NEEDED: bulletPattern still splits on a bare ASCII hyphen ([—–-] after non-greedy source group)."
  exit 0
fi
# Buggy literal absent. Either our patch is applied (still needed conceptually,
# but vanilla tree no longer has the defect) or gbrain rewrote the regex. The
# probe runs against the VANILLA candidate tree, so an absent buggy literal there
# means upstream changed the parser → obsolete.
echo "[tl3-probe] OBSOLETE: buggy bare-hyphen bulletPattern absent from the (vanilla) extract.ts — upstream changed the parser; review and retire FIX-TL-3."
exit 1
