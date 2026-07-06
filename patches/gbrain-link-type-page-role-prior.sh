#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-link-type-page-role-prior.sh   (FIX-TE-3)
#
# WHY THIS EXISTS
# `inferLinkType` (src/core/link-extraction.ts) ends with a PAGE-ROLE PRIOR that
# tests the WHOLE-PAGE text (`globalContext`), not the per-link context window:
#
#   if (pageType === 'person' && globalContext && targetSlug?.startsWith('companies/')) {
#     if (PARTNER_ROLE_RE.test(globalContext))  return 'invested_in';
#     if (ADVISOR_ROLE_RE.test(globalContext))  return 'advises';
#     if (EMPLOYEE_ROLE_RE.test(globalContext)) return 'works_at';
#   }
#
# Because `globalContext` is the ENTIRE person page, a single role phrase anywhere
# on the page ("CEO of X", "employee at Y") makes EVERY company that page merely
# MENTIONS — and whose local context didn't already match a specific verb — resolve
# to works_at / invested_in / advises. On the prose-first person pages (each
# discusses dozens of companies) this is catastrophic:
#
#   Measured 2026-07-06 on the Venture-Formations brain:
#     2,873 works_at edges are link_source='markdown' (co-occurrence) vs 28
#     link_source='frontmatter' (curated `company:` projection).
#     people/jason-lemkin "works_at" 31 companies — Anthropic, OpenAI, SpaceX,
#     Stripe, even "China" and "Monaco" — when he works at ONE (SaaStr).
#     companies/cursor "works_at" Sam Bankman-Fried, Chamath, Calacanis, Lemkin.
#
# A page-LEVEL signal must not drive LINK-LEVEL typing. This patch DISABLES the
# page-role prior block. What remains is correct and precise:
#   - The LOCAL sentence-context verb regexes above the prior (FOUNDED_RE /
#     INVESTED_RE / ADVISES_RE / WORKS_AT_RE tested on the 240-char `context`
#     window) — untouched; they fire only when THIS link's own sentence is about
#     employment/investment/founding.
#   - The authoritative employer/investor edges from FRONTMATTER (`company:`,
#     `companies:`, `investors:`, `key_people:`) — untouched; that is the
#     identity-grade provenance downstream derivations already trust.
#   - Neutral company mentions now correctly fall through to `return 'mentions'`.
#
# Scope decision (operator, 2026-07-06): remove ALL THREE priors (works_at +
# invested_in + advises), not just works_at — the whole-page-signal flaw is
# identical for the investment and advisor verbs and pollutes those edges too.
#
# RELATION TO FIX-TE-1: FIX-TE-1 added endpoint guards (A: *→person; B: non-person
# founded) at the TOP of inferLinkType and explicitly left the role-prior layer
# in place ("already correctly gated on pageType==='person' && companies/"). That
# gating is ENDPOINT-correct but CONTENT-wrong (page-wide vs link-level) — a
# different defect FIX-TE-1 did not address. FIX-TE-3 completes the picture.
#
# ANCHOR: the exact page-role-prior `if (...)` line. It is unique in the file and
# sits inside `export function inferLinkType`. If gbrain refactors the function
# the anchor check below FAILS THE BUILD (old container keeps serving) so a bad
# extraction never storms in silently.
#
# Idempotent: re-running after a successful patch is a no-op (FIX-TE-3 sentinel).
# Order dependency: independent of TE-1/TE-2 (different region of the same
# function); safe to run in any order relative to them. The Dockerfile places it
# immediately after the TE-1 line for locality.
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
  echo "[gbrain-patch:te-3] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

FILE="$GBRAIN_SRC/core/link-extraction.ts"
if [ ! -f "$FILE" ]; then
  echo "[gbrain-patch:te-3] ERROR: $FILE not found." >&2
  exit 1
fi
echo "[gbrain-patch:te-3] target: $FILE"

# ── Idempotency sentinel ─────────────────────────────────────────────────────
if grep -qF 'FIX-TE-3' "$FILE"; then
  echo "[gbrain-patch:te-3] ✓ already applied (FIX-TE-3 sentinel present); no-op."
  exit 0
fi

# ── Self-auditing anchor check ───────────────────────────────────────────────
# The three role-prior lines must be present in their exact shape. If gbrain
# refactors the prior (renames the REs, restructures the block) these checks fail
# and the build fails LOUDLY rather than silently mis-splicing.
ANCHOR="if (pageType === 'person' && globalContext && targetSlug?.startsWith('companies/')) {"
if ! grep -qF "$ANCHOR" "$FILE"; then
  echo "[gbrain-patch:te-3] ERROR: page-role-prior anchor gone from inferLinkType — gbrain may have refactored it. RE-POINT THIS PATCH (see UPGRADING_GBRAIN.md)." >&2
  exit 1
fi
for line in \
  "if (PARTNER_ROLE_RE.test(globalContext)) return 'invested_in';" \
  "if (ADVISOR_ROLE_RE.test(globalContext)) return 'advises';" \
  "if (EMPLOYEE_ROLE_RE.test(globalContext)) return 'works_at';"; do
  if ! grep -qF "$line" "$FILE"; then
    echo "[gbrain-patch:te-3] ERROR: prior body line missing: '$line' — block shape changed. RE-POINT." >&2
    exit 1
  fi
done

# ── Perl splice: comment out the whole page-role-prior block ────────────────
# Match the exact 5-line block (2-space indented) and replace with a FIX-TE-3
# explanatory comment that keeps the original lines commented for auditability.
perl -0777 -i -pe '
  my $block = q{  if (pageType === '"'"'person'"'"' && globalContext && targetSlug?.startsWith('"'"'companies/'"'"')) {
    if (PARTNER_ROLE_RE.test(globalContext)) return '"'"'invested_in'"'"';
    if (ADVISOR_ROLE_RE.test(globalContext)) return '"'"'advises'"'"';
    if (EMPLOYEE_ROLE_RE.test(globalContext)) return '"'"'works_at'"'"';
  }};
  my $repl = q{  // FIX-TE-3 (hermes-template build patch) — PAGE-ROLE PRIOR DISABLED.
  // The block below tested the WHOLE page (globalContext), so one role phrase
  // anywhere on a person page typed EVERY company that page merely MENTIONED as
  // works_at/invested_in/advises. Measured: 2873 markdown works_at edges vs 28
  // curated frontmatter; jason-lemkin "works_at" 31 companies incl. Anthropic/
  // OpenAI/SpaceX/China/Monaco. Page-level signal must not drive link-level type.
  // The LOCAL sentence-context regexes above (WORKS_AT_RE/INVESTED_RE/ADVISES_RE
  // on `context`) stay and are precise; authoritative employer/investor edges
  // come from frontmatter. Neutral mentions now fall through to '"'"'mentions'"'"'.
  // (Original block, disabled:)
  // if (pageType === '"'"'person'"'"' && globalContext && targetSlug?.startsWith('"'"'companies/'"'"')) {
  //   if (PARTNER_ROLE_RE.test(globalContext)) return '"'"'invested_in'"'"';
  //   if (ADVISOR_ROLE_RE.test(globalContext)) return '"'"'advises'"'"';
  //   if (EMPLOYEE_ROLE_RE.test(globalContext)) return '"'"'works_at'"'"';
  // }};
  my $n = ($_ =~ s/\Q$block\E/$repl/);
  die "[gbrain-patch:te-3] ERROR: block replace matched $n times (expected 1)\n" unless $n == 1;
' "$FILE"

# ── Post-insert verification ─────────────────────────────────────────────────
if [ "$(grep -cF 'FIX-TE-3' "$FILE")" = "0" ]; then
  echo "[gbrain-patch:te-3] ERROR: sentinel not present after splice — replace failed." >&2
  exit 1
fi
# The three role returns must no longer exist as ACTIVE (uncommented) code.
if grep -nE "^\s*if \((PARTNER_ROLE_RE|ADVISOR_ROLE_RE|EMPLOYEE_ROLE_RE)\.test\(globalContext\)" "$FILE" | grep -qv '//'; then
  echo "[gbrain-patch:te-3] ERROR: an active page-role-prior return survived the splice." >&2
  exit 1
fi
# The local sentence-context WORKS_AT_RE positive path must remain intact.
if ! grep -qF "if (WORKS_AT_RE.test(context)) return 'works_at';" "$FILE"; then
  echo "[gbrain-patch:te-3] ERROR: local WORKS_AT_RE path vanished — splice over-matched. Inspect $FILE." >&2
  exit 1
fi

echo "[gbrain-patch:te-3] ✓ page-role prior disabled: page-wide role phrases no longer type company mentions."
echo "[gbrain-patch:te-3] ✓ local sentence-context verb regexes + frontmatter edges intact."
echo "[gbrain-patch:te-3] done."
