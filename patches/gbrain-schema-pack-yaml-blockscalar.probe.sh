#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-schema-pack-yaml-blockscalar.probe.sh (still_needed_probe FIX-SP-YAML)
# Run against the VANILLA candidate tree.
# Exit: 0=STILL NEEDED  1=OBSOLETE  2=UNKNOWN
# ---------------------------------------------------------------------------
set -uo pipefail

GBRAIN_SRC=""
for d in \
  "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
[ -z "$GBRAIN_SRC" ] && { echo "[sp-yaml-probe] UNKNOWN: gbrain src not found." >&2; exit 2; }

T="$GBRAIN_SRC/core/schema-pack/loader.ts"
[ -f "$T" ] || { echo "[sp-yaml-probe] UNKNOWN: loader.ts not found — tree restructured." >&2; exit 2; }

if grep -qF 'VF-FIX-SP-YAML' "$T" 2>/dev/null; then
  echo "[sp-yaml-probe] STILL NEEDED (patched tree: VF-FIX-SP-YAML present — run against vanilla to test obsolescence)."
  exit 0
fi

# Upstream-fix signal: a real YAML parser (js-yaml) imported, OR the block-scalar
# admission removed AND `|`/`>` handling added.
if grep -qiE "from ['\"]js-yaml['\"]|safeLoad|yaml\.load\(" "$T" 2>/dev/null; then
  echo "[sp-yaml-probe] OBSOLETE? loader.ts now imports a real YAML parser (js-yaml/safeLoad) — REVIEW and retire FIX-SP-YAML."
  exit 1
fi
if ! grep -qF 'Block strings via' "$T" 2>/dev/null; then
  echo "[sp-yaml-probe] UNKNOWN: the block-scalar admission comment is gone but no js-yaml import found — parser restructured; manual review." >&2
  exit 2
fi
echo "[sp-yaml-probe] STILL NEEDED: parseYamlMini still admits block scalars are unsupported (silent key-drop)."
exit 0
