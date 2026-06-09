#!/usr/bin/env bash
# still_needed_probe for FIX-EN-3 (gbrain-enrich-cli-prompt-twin).
# Answers per upgrade: does the CLI enrich_thin buildEnrichPrompt still ship the
# pre-patch defect shape (a "careful knowledge-base editor" system prompt with NO
# preserve-verbatim rule + compression-biased KIND_SECTION_GUIDANCE)? If gbrain
# added an equivalent preserve-verbatim rule upstream, the protective patch is
# obsolete. Conservative: prefer STILL-NEEDED unless the defect is clearly gone.
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
  echo "[en3-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi
T="$GBRAIN_SRC/core/enrich/thin.ts"
[ -f "$T" ] || { echo "[en3-probe] UNKNOWN: core/enrich/thin.ts not found"; exit 2; }

# The patch anchor: the buildEnrichPrompt system[] prompt header. If gone, the
# prompt was refactored — can't confirm the defect; escalate (patch build would
# fail anyway).
HAS_ANCHOR=$(grep -cF "You are a careful knowledge-base editor." "$T" 2>/dev/null || echo 0)
if [ "$HAS_ANCHOR" -eq 0 ]; then
  echo "[en3-probe] UNKNOWN: buildEnrichPrompt anchor gone — prompt refactored; manual review (patch self-audit would fail the build)."
  exit 2
fi

# Defect signal A: the compression-biased KIND_SECTION_GUIDANCE the patch softens
# still says "concise dossier"/"concise company profile".
COMPRESS=$(grep -cE "Write a concise (dossier|company profile)\." "$T" 2>/dev/null || echo 0)
# Upstream-fix signal: gbrain added its own preserve-verbatim / keep-number rule
# to the prompt (outside our FIX-EN-3 block).
UPSTREAM_RULE=0
if grep -qiE "verbatim|preserve (the )?(number|claim)|do not (round|compress|neutralize)" "$T" 2>/dev/null \
   && ! grep -qF 'FIX-EN-3' "$T" 2>/dev/null; then
  UPSTREAM_RULE=1
fi
echo "[en3-probe] anchor:$HAS_ANCHOR compression-biased-guidance:$COMPRESS upstream-verbatim-rule:$UPSTREAM_RULE"

if [ "$UPSTREAM_RULE" -eq 1 ]; then
  echo "[en3-probe] OBSOLETE: buildEnrichPrompt appears to carry an upstream preserve-verbatim rule — review and retire FIX-EN-3."
  exit 1
fi
echo "[en3-probe] STILL NEEDED: enrich_thin prompt has no preserve-verbatim rule; protective patch keeps the regression out if the cycle is enabled."
exit 0
