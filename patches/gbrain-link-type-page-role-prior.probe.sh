#!/usr/bin/env bash
# still-needed probe for FIX-TE-3 (gbrain-link-type-page-role-prior).
# Exit 0 = STILL NEEDED (the page-role prior is present in stock gbrain).
# Exit 3 = upstream appears fixed (prior gone or gated on local context) → review for deprecation.
set -uo pipefail
GBRAIN_SRC=""
for d in "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
         "/usr/local/bun/install/global/node_modules/gbrain/src"; do
  [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
[ -z "$GBRAIN_SRC" ] && { echo "probe: gbrain src not found"; exit 0; }
F="$GBRAIN_SRC/core/link-extraction.ts"
# If our sentinel is present, the patch already applied — still needed by definition.
grep -qF 'FIX-TE-3' "$F" && { echo "probe: FIX-TE-3 applied; still needed."; exit 0; }
# Stock gbrain still ships the page-wide prior? (tests globalContext)
if grep -qF 'EMPLOYEE_ROLE_RE.test(globalContext)' "$F"; then
  echo "probe: stock page-role prior present (EMPLOYEE_ROLE_RE.test(globalContext)) → STILL NEEDED."
  exit 0
fi
echo "probe: page-role prior absent/changed upstream → REVIEW for deprecation."
exit 3
