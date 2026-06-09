#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-no-anthropic-reroute.sh   (VF FIX-NA-1)
#
# WHY THIS EXISTS — and why it REPLACES gbrain-openrouter-model-defaults.sh
# This deployment provisions NO ANTHROPIC_API_KEY (operator decision: never a
# native Anthropic dependency; OpenRouter may still route to Claude, billed via
# OPENROUTER_API_KEY). gbrain hardcodes native `anthropic:` model strings as the
# default at DOZENS of touchpoints (gateway.ts, model-config.ts DEFAULT_ALIASES,
# page-summary.ts, facts/classify.ts, facts/extract.ts, extract-takes-from-pages.ts,
# synthesize.ts, cycle-phase.ts, operations.ts, jobs.ts, import-file.ts, …) with
# no global config knob. Any that reach a native `anthropic:` recipe throw inside
# gateway.chat() and are SWALLOWED silently (facts/takes extractors return [] /
# continue; fact-dedup degrades to cosine) → the brain silently produces 0 facts.
#
# The OLD patch chased ~20 literals across a dozen files with sed and audited for
# "0 anthropic:claude-* literals remain". On a release-less master that bumps
# 7×/60d, a NEW touchpoint in any shape the regex didn't match = a fresh silent
# zero, with no Anthropic key as a safety net. That coverage boundary is
# structurally unwinnable.
#
# THIS patch is behavioral, not literal. gbrain resolves EVERY model string —
# hardcoded default, config value, DB, env — through ONE chokepoint:
#   resolveRecipe(modelId) -> parseModelId(modelId) -> getRecipe(providerId)
# in src/core/ai/model-resolver.ts. We inject a single guard there: a native
# `anthropic:` id with no ANTHROPIC_API_KEY is re-routed to `openrouter:auto`.
# One site subsumes all the literals AND auto-covers any new touchpoint upstream
# ever adds, because they all resolve through this function. The literals can
# stay — they are harmless once the chokepoint reroutes them.
#
# Companion: anthropic-scan.sh (fail-closed: asserts this sentinel is present
# and that no NEW native-anthropic client-construction site bypasses the
# chokepoint) runs right after this in the Dockerfile and in verify-upgrade.sh.
#
# Applied at Docker BUILD time after the gbrain install; re-applied on every
# GBRAIN_REF bump; idempotent; safe to re-run on a live container. FAILS THE
# BUILD LOUDLY (old container keeps serving — no outage) if its anchor moved,
# so the anchor gets re-pointed (never a silent no-op). See UPGRADING_GBRAIN.md.
# ---------------------------------------------------------------------------
set -euo pipefail

SENTINEL='VF-FIX-NA-1'
ANCHOR='const parsed = parseModelId(modelId);'

# Resolve the gbrain source tree across build + runtime layouts.
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[na-reroute] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
TARGET="$GBRAIN_SRC/core/ai/model-resolver.ts"
echo "[na-reroute] target: $TARGET"

if [ ! -f "$TARGET" ]; then
  echo "[na-reroute] ERROR: $TARGET missing — gbrain moved the model resolver. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi

# Idempotent: already applied?
if grep -qF "$SENTINEL" "$TARGET"; then
  echo "[na-reroute] ✓ already applied ($SENTINEL present) — no-op."
  exit 0
fi

# Preflight: the anchor MUST be present. A moved anchor is a LOUD build failure,
# never a silent skip — that is the whole point ("don't just have silent patch
# failures").
if ! grep -qF "$ANCHOR" "$TARGET"; then
  echo "[na-reroute] ERROR: anchor not found in $TARGET:" >&2
  echo "[na-reroute]   anchor: $ANCHOR" >&2
  echo "[na-reroute] gbrain moved/renamed the resolveRecipe chokepoint. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD (old container keeps serving)." >&2
  exit 1
fi

# Inject the reroute immediately after the resolveRecipe anchor line. sed `r`
# reads the insert file in after the matched line (BRE: parens are literal).
INSERT=$(mktemp)
cat > "$INSERT" <<'TS'
  // [VF-FIX-NA-1] no-native-anthropic reroute — single-chokepoint guard.
  // This deployment provisions no ANTHROPIC_API_KEY. Rather than chase every
  // hardcoded `anthropic:` default across the tree, re-route here — the one
  // place every model string resolves. A native `anthropic:` id with no key
  // becomes `openrouter:auto` (OpenRouter may still pick Claude, billed via
  // OPENROUTER_API_KEY — never the Anthropic API). Behavioral, not literal:
  // covers any new touchpoint upstream adds. If `openrouter` is unconfigured,
  // getRecipe throws loudly below (never a silent failure).
  if (parsed.providerId === 'anthropic' && !process.env.ANTHROPIC_API_KEY) {
    return resolveRecipe('openrouter:auto');
  }
TS

# Escape the anchor for BRE (only `/` needs care as the sed delimiter; we use @).
sed -i "\@${ANCHOR}@r ${INSERT}" "$TARGET"
rm -f "$INSERT"

# Post-audit: the reroute MUST now be present. If injection did not land, FAIL
# the build — never report success on a no-op patch.
if ! grep -qF "$SENTINEL" "$TARGET"; then
  echo "[na-reroute] ERROR: post-apply audit failed — $SENTINEL absent after sed. Injection did not land. FAILING THE BUILD." >&2
  exit 1
fi
# Defensive: the reroute call must reference openrouter:auto (catches a mangled insert).
if ! grep -qF "resolveRecipe('openrouter:auto')" "$TARGET"; then
  echo "[na-reroute] ERROR: post-apply audit failed — reroute target literal missing. FAILING THE BUILD." >&2
  exit 1
fi
echo "[na-reroute] ✓ applied: native anthropic: ids with no key now re-route to openrouter:auto at the resolveRecipe chokepoint."
echo "[na-reroute] done."
