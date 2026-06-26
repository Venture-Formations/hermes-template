#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-dir-pattern-owned-dirs.sh   (FIX-DP-1, prose-first overhaul A1b)
#
# WHY THIS EXISTS
# link-extraction's DIR_PATTERN (src/core/link-extraction.ts:86) is the closed
# alternation of directory prefixes that the markdown-link / [[wikilink]] regexes
# accept when turning a link into a source->entity EDGE. Only a prefix in this
# pattern produces an edge; a link under any other dir is ignored by the graph.
#
# The prose-first overhaul owns two new entity namespaces that must be edge-
# producing: `products/` (product pages) and `publications/` (publication pages).
# DIR_PATTERN already contains people|companies|concepts|tech|media (verified at
# the pin), but NOT products|publications, so `[[products/cursor]]` and
# `[[publications/zero-to-one]]` would silently fail to link. This patch adds
# exactly those two tokens to the alternation. Stage-3 routes synthesis on
# `frontmatter.type`, so the directory only needs to be edge-producing — nothing
# else about type resolution depends on this.
#
# ANCHOR: the literal head of the DIR_PATTERN assignment plus its known tail
# `openclaw|entities)';`. Both are asserted present before the splice; if gbrain
# reorders or renames the alternation the anchor check FAILS THE BUILD (the old
# container keeps serving) rather than silently producing a wrong pattern.
#
# What we do NOT change: the regexes that consume DIR_PATTERN, the QUALIFIED /
# MARKDOWN_LABEL variants, or any other prefix already in the alternation.
# ---------------------------------------------------------------------------
set -euo pipefail

G="${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain"
T="$G/src/core/link-extraction.ts"
[ -f "$T" ] || { echo "[FIX-DP-1] target missing: $T" >&2; exit 1; }

# Idempotent: re-runs after every gbrain install on each GBRAIN_REF bump.
if grep -qE "products\|publications" "$T"; then
  echo "[FIX-DP-1] already applied (products|publications present) — no-op"
  exit 0
fi

# Anchor self-audit — fail the Docker build if the DIR_PATTERN shape moved.
grep -qF "const DIR_PATTERN = '(?:people|companies|meetings|concepts" "$T" \
  || { echo "[FIX-DP-1] ANCHOR GONE — DIR_PATTERN head changed; aborting build" >&2; exit 1; }
grep -qF "openclaw|entities)';" "$T" \
  || { echo "[FIX-DP-1] DIR_PATTERN tail 'openclaw|entities)' changed; aborting build" >&2; exit 1; }

# Splice the two owned dirs into the alternation, scoped to the known tail so no
# other 'entities)' occurrence can be touched.
perl -pi -e "s/openclaw\|entities\)';/openclaw|entities|products|publications)';/" "$T"

grep -qE "products\|publications\)';" "$T" \
  || { echo "[FIX-DP-1] splice did not take; aborting build" >&2; exit 1; }
echo "[FIX-DP-1] applied: products|publications added to DIR_PATTERN"
