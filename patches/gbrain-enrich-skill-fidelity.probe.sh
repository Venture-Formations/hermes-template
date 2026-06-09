#!/usr/bin/env bash
# still_needed_probe for FIX-EN-1/EN-2 (gbrain-enrich-skill-fidelity).
# Answers per upgrade: does the live enrich SKILL.md still lack an enforced
# verbatim-claim + contradiction-reconciliation rule? If garrytan/gbrain shipped
# an equivalent rule upstream, retire the patch. Conservative: prefer STILL-NEEDED.
# Exit 0 = still needed, 1 = obsolete (recommend retire), 2 = unknown.
set -uo pipefail
# This patch targets the gbrain install ROOT (skills/...), not src/. Resolve the
# tree root, then locate the skill file under it.
GBRAIN_SRC=""
for d in "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[enfid-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi
ROOT="$(dirname "$GBRAIN_SRC")"
SKILL="$ROOT/skills/enrich/SKILL.md"
[ -f "$SKILL" ] || { echo "[enfid-probe] UNKNOWN: skills/enrich/SKILL.md not found"; exit 2; }

# Anchor the patch inserts before; if gone, the skill was restructured.
HAS_ANCHOR=$(grep -cF "## Output Format" "$SKILL" 2>/dev/null || echo 0)
if [ "$HAS_ANCHOR" -eq 0 ]; then
  echo "[enfid-probe] UNKNOWN: '## Output Format' anchor gone — enrich SKILL.md restructured; manual review."
  exit 2
fi

# Upstream-fix signal: a native contradiction-segregation heading or a verbatim
# preserve-claim instruction, present OUTSIDE our FIX-EN-1/2 sentinel block.
UPSTREAM=0
if grep -qF 'FIX-EN-1/2 BEGIN' "$SKILL" 2>/dev/null; then
  UPSTREAM=0   # our patch is what's present; defect still requires us
else
  if grep -qiE "Contradictions / Open Disputes|preserve .*(verbatim|the number)|verbatim .*(claim|number)" "$SKILL" 2>/dev/null; then
    UPSTREAM=1
  fi
fi
echo "[enfid-probe] anchor:$HAS_ANCHOR upstream-fidelity-rule:$UPSTREAM"

if [ "$UPSTREAM" -eq 1 ]; then
  echo "[enfid-probe] OBSOLETE: enrich SKILL.md appears to carry an upstream verbatim-claim/contradiction rule — review and retire FIX-EN-1/EN-2."
  exit 1
fi
echo "[enfid-probe] STILL NEEDED: enrich SKILL.md still has no enforced verbatim-claim + contradiction-reconciliation rule."
exit 0
