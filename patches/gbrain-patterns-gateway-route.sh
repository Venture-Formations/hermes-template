#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-patterns-gateway-route.sh   (VF FIX-PG-1)
#
# WHY THIS EXISTS
# The patterns dream phase (cross-session theme detection) hard-gates on a
# literal native key in src/core/cycle/patterns.ts:
#     if (!process.env.ANTHROPIC_API_KEY) {
#       return skipped('no_api_key', 'ANTHROPIC_API_KEY unset; pattern detection skipped');
#     }
# This deployment provisions NO ANTHROPIC_API_KEY (operator decision; the brain
# runs on grok via the Hermes xAI-OAuth proxy + FIX-NA-1 reroute). So the phase
# returns skipped('no_api_key') on EVERY cycle — in autopilot AND the nightly
# dream-cycle.sh loop — and NO pattern pages are ever produced. The gate sits
# BEFORE any model resolution, so FIX-NA-1 cannot help: the phase short-circuits
# before the resolveRecipe chokepoint is reached.
#
# THE GATE IS THE WRONG CHECK. patterns.ts owns no LLM client — it submits a
# `subagent` MinionQueue job (patterns.ts ~L88). With agent.use_gateway_loop=true
# (boot-pinned), the subagent handler routes via runSubagentViaGateway ->
# gateway.toolLoop -> resolveRecipe (src/core/ai/gateway.ts), the EXACT FIX-NA-1
# chokepoint, so a native anthropic: id reroutes to grok ($0). The model passed
# is always provider-prefixed (resolveModel -> resolveAlias -> anthropic:claude-
# sonnet-4-6 / grok:grok-4.3), so it passes the subagent capability gate. And the
# legacy native path is FIX-NA-2-guarded (throws ERR_NATIVE_ANTHROPIC_BLOCKED with
# no key) — it can never silently reach/bill Anthropic. So removing this env gate
# is SAFE: patterns runs on grok via the gateway, or fails LOUD; never native-bills.
#
# WHAT THIS PATCH DOES
# Replaces the native-key gate with an explanatory no-op pass-through (the phase
# proceeds to submit the gateway-routed subagent). When reflections are below
# min_evidence the phase still skips earlier ('insufficient_evidence'), so this
# does not introduce runaway cost — it spends only when real reflections exist.
#
# ANCHOR (must be present EXACTLY ONCE):
#   src/core/cycle/patterns.ts:
#     if (!process.env.ANTHROPIC_API_KEY) {
#       return skipped('no_api_key', 'ANTHROPIC_API_KEY unset; pattern detection skipped');
#     }
#
# This is a gbrain *core* modification. Applied at Docker BUILD time after the
# gbrain bake AND AFTER gbrain-no-anthropic-reroute.sh (FIX-NA-1) + anthropic-scan
# (the reroute this patch relies on must already be in place); baked into the
# image; re-applied on every GBRAIN_REF bump; idempotent (no-op if the FIX-PG-1
# sentinel is present); FAILS THE BUILD LOUDLY (old container keeps serving) if
# the anchor moved/changed, forcing a re-point. See UPGRADING_GBRAIN.md. Filed
# upstream (the native-env gate breaks the patterns phase for any non-Anthropic
# gateway deployment); retire when garrytan/gbrain drops the literal key gate and
# routes patterns through the gateway like every other phase.
# ---------------------------------------------------------------------------
set -euo pipefail

GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[gbrain-patch:pg-1] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

TARGET="$GBRAIN_SRC/core/cycle/patterns.ts"
if [ ! -f "$TARGET" ]; then
  echo "[gbrain-patch:pg-1] ERROR: $TARGET not found — gbrain moved the patterns phase. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi
echo "[gbrain-patch:pg-1] target: $TARGET"

SENTINEL="// FIX-PG-1"

# Idempotent: already applied?
if grep -qF "$SENTINEL" "$TARGET"; then
  echo "[gbrain-patch:pg-1] ✓ already applied (FIX-PG-1 sentinel present); no-op."
  exit 0
fi

# --- ANCHOR (the two-line native-key gate; must be present EXACTLY ONCE) ----
OLD="    if (!process.env.ANTHROPIC_API_KEY) {
      return skipped('no_api_key', 'ANTHROPIC_API_KEY unset; pattern detection skipped');
    }"
NEW="    // ${SENTINEL} (hermes-template build patch): the vanilla line here was
    //   if (!process.env.ANTHROPIC_API_KEY) return skipped('no_api_key', ...)
    // which made the patterns phase a permanent no-op on this fork (NO native
    // ANTHROPIC_API_KEY — the brain runs on grok via the Hermes xAI-OAuth proxy
    // + FIX-NA-1). The gate sat BEFORE model resolution, so FIX-NA-1 could not
    // help. patterns owns no LLM client; it submits a subagent MinionQueue job
    // below. With agent.use_gateway_loop=true (boot-pinned) the subagent handler
    // routes via runSubagentViaGateway -> gateway.toolLoop -> resolveRecipe (the
    // FIX-NA-1 chokepoint), so the resolved anthropic: id reroutes to grok (\$0);
    // the legacy native path is FIX-NA-2-guarded (throws with no key, never
    // silently bills). So we DELETE the env gate and let the gateway-routed
    // subagent run. The phase still skips earlier ('insufficient_evidence') when
    // reflections < min_evidence, so this adds no runaway cost. See
    // gbrain-patterns-gateway-route.meta.yml."

n=$(grep -cF "    if (!process.env.ANTHROPIC_API_KEY) {" "$TARGET" || true)
if [ "$n" -eq 0 ]; then
  echo "[gbrain-patch:pg-1] ERROR: anchor not found in $TARGET (the native-key gate). gbrain changed the patterns phase. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD (old container keeps serving)." >&2
  exit 1
elif [ "$n" -gt 1 ]; then
  echo "[gbrain-patch:pg-1] ERROR: native-key gate is AMBIGUOUS ($n matches) in $TARGET — a precise splice needs exactly one site. RE-POINT. FAILING THE BUILD." >&2
  exit 1
fi

# APPLY — exact multi-line replacement, count-asserted (mirrors FIX-TQ-1 / FIX-AD-1).
OLD="$OLD" NEW="$NEW" python3 - "$TARGET" <<'PYEOF'
import os, sys
path = sys.argv[1]
old = os.environ['OLD']
new = os.environ['NEW']
s = open(path, encoding='utf-8').read()
if s.count(old) != 1:
    sys.stderr.write("[gbrain-patch:pg-1] ERROR(py): expected exactly 1 occurrence of the native-key gate in %s, found %d. FAILING.\n" % (path, s.count(old)))
    sys.exit(1)
open(path, 'w', encoding='utf-8').write(s.replace(old, new))
PYEOF

# POST-AUDIT — sentinel present; the native-key gate is gone.
if ! grep -qF "$SENTINEL" "$TARGET"; then
  echo "[gbrain-patch:pg-1] ERROR: post-apply audit failed — FIX-PG-1 sentinel absent after edit. FAILING THE BUILD." >&2
  exit 1
fi
if grep -qF "return skipped('no_api_key', 'ANTHROPIC_API_KEY unset; pattern detection skipped');" "$TARGET"; then
  echo "[gbrain-patch:pg-1] ERROR: post-apply audit failed — the no_api_key skip is still present. FAILING THE BUILD." >&2
  exit 1
fi
echo "[gbrain-patch:pg-1] ✓ applied: patterns.ts native-key gate removed — the patterns phase now runs its subagent through the gateway (FIX-NA-1 -> grok)."
echo "[gbrain-patch:pg-1] done."
