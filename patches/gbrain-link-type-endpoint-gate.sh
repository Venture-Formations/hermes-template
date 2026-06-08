#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-link-type-endpoint-gate.sh   (FIX-TE-1)
#
# WHY THIS EXISTS
# `inferLinkType` (src/core/link-extraction.ts:683) runs the per-edge verb
# regexes (FOUNDED_RE / INVESTED_RE / ADVISES_RE / WORKS_AT_RE) against the
# 240-char context window BEFORE checking whether the TARGET endpoint type is
# semantically compatible with the verb.  The result is a class of structurally
# impossible edges that constitute the bulk of the graph garbage in this brain:
#
#   person→person  works_at       (e.g. gavin-baker → 24 false edges)
#   person→person  invested_in    (investment toward a person endpoint)
#   person→person  founded        (a person "founded" another person)
#   person→person  advises        (debatable; kept in scope — advising a person
#                                  is semantically possible, but the verb regexes
#                                  fire on company-context language near person
#                                  slugs, so this is still a false-positive class)
#   company→company founded       (a company "founded" another company — the
#                                  `inferTypeByDir` FS-path already blocks this
#                                  because it requires from='people')
#
# The FS-source path (`inferTypeByDir`, extract.ts:345-356) is already
# endpoint-aware — it keys on from/to directory prefixes and returns `mentions`
# for every combination that lacks a canonical verb.  The DB-source path
# (`inferLinkType`) lacks this gate.  This patch adds the MINIMUM gate needed to
# make the DB path converge toward `inferTypeByDir`'s already-correct contract:
#
#   GUARD A  — before any verb regex runs:
#     if the resolved targetSlug starts with 'people/', suppress all typed verbs
#     → 'mentions'.  This blocks person→person and *→person employment/
#     investment/founding (the dominant false-positive class).
#
#   GUARD B  — before FOUNDED_RE only:
#     if pageType is NOT 'person' (and not already caught by meeting/image/
#     source/media early returns), suppress 'founded'.  The canonical model is
#     person→company only.  A company page mentioning another company with the
#     word "founded" should produce 'mentions', not a company→company founded
#     edge (which is how gavin-baker→Acme and similar false edges arise on
#     COMPANY pages that describe a portfolio company's history).
#
# What we do NOT change:
#   - person→company works_at / invested_in / founded / advises — fully intact.
#   - The BrainBench-calibrated regex bodies themselves (FOUNDED_RE, INVESTED_RE,
#     ADVISES_RE, WORKS_AT_RE, role priors) — untouched.
#   - The role-prior layer (lines 707-711) — already correctly gated on
#     `pageType === 'person' && targetSlug?.startsWith('companies/')`.
#   - Any edge where targetSlug is undefined/unknown — also unchanged (the guard
#     is `targetSlug?.startsWith(...)`, so a missing slug skips the gate).
#     This preserves the behaviour when the caller hasn't resolved the slug yet.
#
# ANCHOR: `// Per-edge verb rules.` comment, which immediately precedes the
# FOUNDED_RE / INVESTED_RE / ADVISES_RE / WORKS_AT_RE block (line 693 at
# gbrain@099d9a8).  The anchor is inside `export function inferLinkType` and is
# stable — it is the structural comment that introduces the verb-rule layer.
# If gbrain refactors inferLinkType and removes that comment, the anchor check
# below FAILS THE BUILD so the upgrade catch fires before a bad edge storms in.
#
# ⚠️ BENCHMARK NOTE: inferLinkType is calibrated against the BrainBench
# rich-prose corpus (94.4% templated / 85% rich-prose targets,
# link-extraction.ts:590-665).  This patch ONLY tightens FALSE-POSITIVE verbs
# (impossible endpoint combinations); it does NOT alter any regex body or
# weaken any true-positive path.  The risk is a false-negative on edge cases
# where "founded" is used metaphorically on a company page (e.g. "Company X was
# founded by...") — those would correctly flip from 'founded' to 'mentions'
# under Guard B.  That IS the desired outcome: company→company 'founded' is a
# structural error.
#
# Idempotent: re-running after a successful patch is a no-op (sentinel check).
# Order dependency: run AFTER gbrain-source-pages-mentions-only.sh (FIX-TE-2)
# so both patches see the same post-install tree.  The Dockerfile RUN line for
# this patch must come after the TE-2 line.
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Resolve gbrain source tree (mirrors all other patches exactly) ──────────
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[gbrain-patch:te-1] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

FILE="$GBRAIN_SRC/core/link-extraction.ts"
if [ ! -f "$FILE" ]; then
  echo "[gbrain-patch:te-1] ERROR: $FILE not found." >&2
  exit 1
fi
echo "[gbrain-patch:te-1] target: $FILE"

# ── Self-auditing anchor check ───────────────────────────────────────────────
# The anchor is the unique structural comment that introduces the per-edge verb
# block inside inferLinkType.  If gbrain refactors the function (renames the
# comment, inlines the block, etc.) this will catch it and fail the build so the
# patch is never silently skipped or mis-applied.
ANCHOR="// Per-edge verb rules."
if ! grep -qF "$ANCHOR" "$FILE"; then
  echo "[gbrain-patch:te-1] ERROR: per-edge-verb-rules anchor gone from inferLinkType — gbrain may have refactored this function. RE-POINT THIS PATCH (see UPGRADING_GBRAIN.md)." >&2
  exit 1
fi

# ── Idempotency sentinel ─────────────────────────────────────────────────────
if grep -qF 'FIX-TE-1' "$FILE"; then
  echo "[gbrain-patch:te-1] ✓ already applied (FIX-TE-1 sentinel present); no-op."
  exit 0
fi

# ── Verify the exact per-edge block shape we are inserting BEFORE ────────────
# We need to confirm the FOUNDED_RE / INVESTED_RE / ADVISES_RE / WORKS_AT_RE
# lines follow the anchor comment — if gbrain moved them, the perl splice below
# would insert the guard at the wrong place.
VERB_BLOCK_CHECK="if (FOUNDED_RE.test(context)) return 'founded';"
if ! grep -qF "$VERB_BLOCK_CHECK" "$FILE"; then
  echo "[gbrain-patch:te-1] ERROR: FOUNDED_RE check not found after anchor — infer block shape changed. RE-POINT." >&2
  exit 1
fi

# ── Build the guard block to insert ─────────────────────────────────────────
# We insert TWO guards immediately BEFORE `// Per-edge verb rules.`:
#
#   GUARD A: targetSlug?.startsWith('people/') → 'mentions'
#     Blocks person→person and *→person for ALL employment/investment verbs.
#     This is the dominant false-positive class (gavin-baker et al.).
#
#   GUARD B: non-person source for founded → 'mentions'
#     The FS path already gates founded to from='people' only.  Mirror that
#     here: if pageType is not 'person' (and we haven't already returned from
#     the meeting/image/source/media early-returns), suppress founded.
#     NOTE: we check `pageType !== 'person'` rather than listing exhaustive
#     non-person types, so future schema-pack types are covered automatically.
#
# The guards sit BEFORE the verb regexes run so they take full precedence.
# They do NOT touch the role-prior layer (lines 707-711) which is already
# correctly endpoint-gated.

read -r -d '' GUARD_BLOCK <<'GUARD_EOF' || true
  // FIX-TE-1 (hermes-template build patch) — endpoint/directionality gate.
  //
  // GUARD A: Suppress employment/investment/founding verbs when the TARGET is a
  // person.  person→person works_at / invested_in / founded / advises are
  // structurally impossible: you work AT a company, not AT a person.  This is
  // the dominant false-positive class in this brain (gavin-baker → 24 false
  // edges, all fired because WORKS_AT_RE / INVESTED_RE matched token proximity
  // while the target slug happened to be people/<someone>).
  //
  // Mirror: inferTypeByDir (extract.ts:345-356) is already endpoint-aware — it
  // returns 'mentions' for all combinations that lack a canonical direction.
  // This gate makes the DB path converge toward that contract.
  //
  // NOTE: targetSlug is optional (callers may omit it).  When absent, the gate
  // is skipped and the verb regexes run as before — no regression on that path.
  if (targetSlug?.startsWith('people/')) {
    return 'mentions'; // FIX-TE-1 Guard A: *→person never yields a typed verb
  }
  // GUARD B: Suppress 'founded' for non-person source pages.
  // The canonical 'founded' edge is person→company only (mirroring inferTypeByDir
  // which requires from='people').  A company page saying "X was founded by Y"
  // describes its own history — the link from the company page to another company
  // mentioned in that context should be 'mentions', not company→company 'founded'.
  // pageType has already been checked for 'media', 'image', 'meeting' (and
  // 'source' after FIX-TE-2) — the only non-person type that reaches here and
  // would fire FOUNDED_RE is 'company' (or 'concept'/'analysis'/etc).
  if (pageType !== 'person' && FOUNDED_RE.test(context)) {
    return 'mentions'; // FIX-TE-1 Guard B: founded only valid from person pages
  }

GUARD_EOF

# ── Perl splice: insert the guard block BEFORE `// Per-edge verb rules.` ────
# Strategy: slurp the whole file, replace the anchor comment (exactly once)
# with our guard block + the anchor comment.  The anchor is unique within the
# inferLinkType function so a single-occurrence replacement is safe.
ANCHOR_ESC="  // Per-edge verb rules."
GUARD_BLOCK="$GUARD_BLOCK" ANCHOR_ESC="$ANCHOR_ESC" perl -0777 -i -pe '
  my $g = $ENV{GUARD_BLOCK};
  my $a = $ENV{ANCHOR_ESC};
  # Insert guard before anchor, once only.
  s/\Q$a\E/$g$a/ unless /FIX-TE-1/;
' "$FILE"

# ── Post-insert verification ─────────────────────────────────────────────────
if [ "$(grep -cF 'FIX-TE-1' "$FILE")" = "0" ]; then
  echo "[gbrain-patch:te-1] ERROR: insert did not land — the per-edge-verb block may have moved. RE-POINT." >&2
  exit 1
fi

# Sanity: the FOUNDED_RE guard still exists after patch (wasn't accidentally
# removed by the splice — we inserted before it, not replacing it).
if ! grep -qF "$VERB_BLOCK_CHECK" "$FILE"; then
  echo "[gbrain-patch:te-1] ERROR: FOUNDED_RE line vanished after patch — splice error. Inspect $FILE." >&2
  exit 1
fi

echo "[gbrain-patch:te-1] ✓ Guard A: *→person targets now return 'mentions' before verb regexes run."
echo "[gbrain-patch:te-1] ✓ Guard B: non-person source pages now return 'mentions' before FOUNDED_RE runs."
echo "[gbrain-patch:te-1] ✓ person→company works_at / invested_in / advises / founded: fully intact."
echo "[gbrain-patch:te-1] done."
