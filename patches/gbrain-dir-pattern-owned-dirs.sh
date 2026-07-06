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
# The prose-first overhaul owns FOUR entity/source namespaces that must be edge-
# producing but that DIR_PATTERN does not whitelist (it ships `source` SINGULAR,
# plus our earlier tech|finance|personal|openclaw|entities extensions):
#   - `products/`      (product pages)      — company build   [FIX-DP-1]
#   - `publications/`  (publication pages)  — company build   [FIX-DP-1]
#   - `episodes/`      (episode pages)      — person build    [folds in FIX-LD-1]
#   - `sources/`       (podcast/web source pages, PLURAL)     [folds in FIX-LD-1]
# Without them, `[[products/cursor]]`, `[[publications/zero-to-one]]`, and — the
# person→episode edge gap — the person/company builders' hundreds of
# `[[episodes/youtube/<id>|Title]]` / `[[sources/snipd/<id>|Label]]` Timeline +
# Sources wikilinks all silently fail to link (the no-gate generic pass only fires
# for BARE `[[name]]` refs, and only with link_resolution.global_basename enabled,
# which it is not) — so synthesized people/companies form NO edges to the episodes
# that evidence them (~488 of ~842 people, and those legacy snipd appeared_in, not
# builder refs). This patch adds all four tokens to the alternation. Stage-3 routes
# synthesis on `frontmatter.type`, so the directory only needs to be edge-producing
# — nothing else about type resolution depends on this. episodes|sources folds in
# the standalone FIX-LD-1 patch (same DIR_PATTERN line — one patch owns it).
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

# Idempotent: re-runs after every gbrain install on each GBRAIN_REF bump. Detect
# the COMPLETE applied form (all four dirs) so a partial state is never accepted.
if grep -qF "products|publications|episodes|sources)';" "$T"; then
  echo "[FIX-DP-1] already applied (products|publications|episodes|sources present) — no-op"
  exit 0
fi

# Anchor self-audit — fail the Docker build if the DIR_PATTERN shape moved. The
# anchors are the VANILLA gbrain shape (fresh install each build): the head, and
# the tail `openclaw|entities)';` that the splice targets.
grep -qF "const DIR_PATTERN = '(?:people|companies|meetings|concepts" "$T" \
  || { echo "[FIX-DP-1] ANCHOR GONE — DIR_PATTERN head changed; aborting build" >&2; exit 1; }
grep -qF "openclaw|entities)';" "$T" \
  || { echo "[FIX-DP-1] DIR_PATTERN tail 'openclaw|entities)' changed; aborting build" >&2; exit 1; }

# Splice the four owned dirs into the alternation, scoped to the known tail so no
# other 'entities)' occurrence can be touched.
perl -pi -e "s/openclaw\|entities\)';/openclaw|entities|products|publications|episodes|sources)';/" "$T"

grep -qF "products|publications|episodes|sources)';" "$T" \
  || { echo "[FIX-DP-1] splice did not take; aborting build" >&2; exit 1; }
# The resulting DIR_PATTERN must still COMPILE (a malformed alternation would throw
# at gbrain import → silent extraction death).
DP_TARGET="$T" node -e 'const fs=require("fs");const s=fs.readFileSync(process.env.DP_TARGET,"utf8");const m=s.match(/const DIR_PATTERN = '\''([^'\'']+)'\'';/);if(!m){console.error("[FIX-DP-1] DIR_PATTERN not found post-splice");process.exit(1)}try{new RegExp(m[1])}catch(e){console.error("[FIX-DP-1] DIR_PATTERN does not compile: "+e.message);process.exit(1)}' \
  || exit 1
echo "[FIX-DP-1] applied: products|publications|episodes|sources added to DIR_PATTERN"
