#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-schema-pack-resolve-merge.probe.sh  (still_needed_probe for FIX-SP-MERGE)
#
# "Did gbrain land the extends-merge follow-up upstream, so this patch retires?"
# Run against the VANILLA (un-patched) candidate tree.
#
# Exit codes (harness contract): 0=STILL NEEDED  1=OBSOLETE  2=UNKNOWN
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
[ -z "$GBRAIN_SRC" ] && { echo "[sp-merge-probe] UNKNOWN: gbrain src not found." >&2; exit 2; }

T="$GBRAIN_SRC/core/schema-pack/registry.ts"
[ -f "$T" ] || { echo "[sp-merge-probe] UNKNOWN: registry.ts not found — tree restructured; manual review." >&2; exit 2; }

# Our own marker means we're looking at a patched tree, not vanilla — inconclusive.
if grep -qF 'VF-FIX-SP-MERGE' "$T" 2>/dev/null; then
  echo "[sp-merge-probe] STILL NEEDED (patched tree: VF-FIX-SP-MERGE present — run against vanilla to test obsolescence)."
  exit 0
fi

# The bug signature: resolvePack builds the resolved pack from the BARE CHILD.
# Both the admitting comment AND the bare-child closure call.
HAS_COMMENT=0; grep -qF 'Full extends-merging (child-wins) is the v0.41+ T20 follow-up.' "$T" && HAS_COMMENT=1
HAS_BARECHILD=0; grep -qF 'const alias_graph = buildAliasGraph(manifest);' "$T" && HAS_BARECHILD=1

if [ "$HAS_COMMENT" = "0" ] && [ "$HAS_BARECHILD" = "0" ]; then
  echo "[sp-merge-probe] OBSOLETE? both the T20-follow-up comment AND the bare-child closure call are gone — upstream likely landed the merge. REVIEW and retire FIX-SP-MERGE."
  exit 1
fi
if [ "$HAS_BARECHILD" = "1" ]; then
  echo "[sp-merge-probe] STILL NEEDED: resolvePack still computes the alias graph on the bare child manifest (no merge)."
  exit 0
fi
echo "[sp-merge-probe] UNKNOWN: partial signal (comment=$HAS_COMMENT barechild=$HAS_BARECHILD) — registry.ts changed shape; manual review." >&2
exit 2
