#!/usr/bin/env bash
# still_needed_probe for FIX-TE-1 (gbrain-link-type-endpoint-gate).
# Answers per upgrade: does inferLinkType still run the per-edge verb regexes
# WITHOUT being endpoint/directionality aware (no fromType/toType param, no
# *->person or non-person->founded guard)? If gbrain made inferLinkType
# endpoint-aware natively, the patch is obsolete. Conservative: prefer STILL-NEEDED.
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
  echo "[te1-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi
T="$GBRAIN_SRC/core/link-extraction.ts"
[ -f "$T" ] || { echo "[te1-probe] UNKNOWN: core/link-extraction.ts not found"; exit 2; }

# Patch anchor: the per-edge verb block inside inferLinkType. If gone, function
# was refactored — escalate (the patch self-audit would fail the build).
HAS_ANCHOR=$(grep -cF "// Per-edge verb rules." "$T" 2>/dev/null || echo 0)
if [ "$HAS_ANCHOR" -eq 0 ]; then
  echo "[te1-probe] UNKNOWN: '// Per-edge verb rules.' anchor gone — inferLinkType refactored; manual review."
  exit 2
fi

# Defect signal: the BrainBench verb regexes still run on inferLinkType.
HAS_VERBS=$(grep -cE "FOUNDED_RE|INVESTED_RE|WORKS_AT_RE|ADVISES_RE" "$T" 2>/dev/null || echo 0)
# Upstream-fix signal: inferLinkType gained native endpoint awareness
# (fromType/toType param, or its own *->person/people-target guard), OUTSIDE our
# FIX-TE-1 block.
UPSTREAM=0
if ! grep -qF 'FIX-TE-1' "$T" 2>/dev/null; then
  if grep -qE "fromType|toType|targetSlug[^)]*startsWith\('people/'\)|endpoint.*(gate|guard)|directionality" "$T" 2>/dev/null; then
    UPSTREAM=1
  fi
fi
echo "[te1-probe] anchor:$HAS_ANCHOR verb-regexes:$HAS_VERBS upstream-endpoint-aware:$UPSTREAM"

if [ "$UPSTREAM" -eq 1 ]; then
  echo "[te1-probe] OBSOLETE: inferLinkType appears endpoint-aware upstream (fromType/toType or people-target guard) — review and retire FIX-TE-1."
  exit 1
fi
if [ "$HAS_VERBS" -eq 0 ]; then
  echo "[te1-probe] OBSOLETE: per-edge verb regexes no longer present in inferLinkType — review and retire FIX-TE-1."
  exit 1
fi
echo "[te1-probe] STILL NEEDED: inferLinkType runs the per-edge verb regexes with no native endpoint/directionality gate."
exit 0
