#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-grok-recipe.sh   (VF FIX-GROK-1)
#
# WHY THIS EXISTS
# We route the gbrain knowledge engine's LLM calls through the operator's
# grok / SuperGrok subscription via the Hermes xAI-OAuth proxy, instead of
# openrouter:auto. The proxy (`hermes proxy start --provider xai`, supervised
# in start.sh) is an OpenAI-compatible forwarder at http://127.0.0.1:8645/v1
# that STRIPS the inbound Authorization and attaches the operator's xAI OAuth
# from /data/.hermes/auth.json (disk-backed, auto-refreshing, no per-user
# session). The bearer the client sends is IGNORED — so gbrain needs a
# KEYLESS openai-compat recipe that points at the proxy.
#
# WHAT IT DOES (three atomic edits, one smoke gate — see meta `why`):
#   (a) writes a keyless openai-compat `grok` recipe at
#       src/core/ai/recipes/grok.ts (id `grok`, base_url_default
#       http://127.0.0.1:8645/v1, chat touchpoint model grok-4.3,
#       auth_env.required: [] — modeled on ollama/litellm-proxy, the keyless
#       local recipes). gateway.defaultResolveAuth() sees required.length===0
#       and sends `Authorization: Bearer unauthenticated`, which the proxy
#       discards. isAvailable('chat') returns true for an empty-required
#       openai-compat recipe, so chat_model / facts / takes extractors all see
#       the model as available (the keyless path sidesteps the historic
#       chat-unavailable silent-zero). NO dummy env var and NO Dockerfile ENV
#       are required.
#   (b) registers the recipe in src/core/ai/recipes/index.ts (static import +
#       ALL[] entry) so getRecipe('grok') resolves (the registry is
#       bun-compile-safe / static-import-only).
#   (c) RE-POINTS the FIX-NA-1 reroute target (gbrain-no-anthropic-reroute.sh,
#       run earlier in the Dockerfile) from `resolveRecipe('openrouter:auto')`
#       to `resolveRecipe('grok:grok-4.3')`. A bare `grok-4.3` and gbrain's
#       hardcoded native `anthropic:` defaults BOTH normalize to the native
#       anthropic path with no ANTHROPIC_API_KEY → FIX-NA-1 → now grok. One
#       repoint captures every default + utility touchpoint at the single
#       resolveRecipe chokepoint. (a) MUST precede (c) being live or the
#       reroute would resolve an unknown provider and throw — this patch does
#       (a)+(b) THEN (c) in one RUN with a `gbrain --version` gate, so the
#       recipe always exists before anything routes to it.
#
# ORDERING: this patch runs in the Dockerfile AFTER gbrain-no-anthropic-reroute.sh
# (which injects the VF-FIX-NA-1 block emitting openrouter:auto) and AFTER
# anthropic-scan.sh (which only asserts the sentinel, NOT the target literal,
# so the repoint does not disturb it). We deliberately leave the NA patch
# UNTOUCHED (its source_sha, probe, and scan stay valid) and repoint its
# emitted literal here — the recipe + its consumer (the reroute) are thereby
# ONE atomic unit in ONE patch.
#
# Applied at Docker BUILD time after the gbrain install; re-applied on every
# GBRAIN_REF bump; idempotent; safe to re-run on a live container. FAILS THE
# BUILD LOUDLY (old container keeps serving) if an anchor moved, so it gets
# re-pointed (never a silent no-op). See UPGRADING_GBRAIN.md.
# ---------------------------------------------------------------------------
set -euo pipefail

SENTINEL='VF-FIX-GROK-1'

# Resolve the gbrain source tree across build + runtime layouts.
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[grok-recipe] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
RECIPES_DIR="$GBRAIN_SRC/core/ai/recipes"
RECIPE_FILE="$RECIPES_DIR/grok.ts"
INDEX="$RECIPES_DIR/index.ts"
RESOLVER="$GBRAIN_SRC/core/ai/model-resolver.ts"
echo "[grok-recipe] gbrain src: $GBRAIN_SRC"

for f in "$INDEX" "$RESOLVER"; do
  if [ ! -f "$f" ]; then
    echo "[grok-recipe] ERROR: $f missing — gbrain moved the recipe registry / resolver. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
    exit 1
  fi
done

# Anchors we must find before mutating (LOUD on drift, never a silent skip).
ANCHOR_INDEX_IMPORT="import { deepseek } from './deepseek.ts';"
ANCHOR_INDEX_ARRAY="  deepseek,"
ANCHOR_REROUTE_FROM="return resolveRecipe('openrouter:auto');"
# (c) no longer repoints to a grok LITERAL — it repoints to the LIVE default via
# getChatModel() (so a dashboard model switch propagates to the hardcoded-anthropic
# utility tier too), with a guaranteed-reachable grok:grok-4.3 fallback. These two
# anchors gate that edit:
ANCHOR_RESOLVER_IMPORT="import { AIConfigError } from './errors.ts';"          # import insertion point
REROUTE_SENTINEL="_d = getChatModel()"                                          # presence == guarded form landed (idempotency + audit)

# ---------------------------------------------------------------------------
# (a) Write the keyless openai-compat grok recipe. Always (re)write so an
#     upgrade that changes the Recipe type can't leave a stale shape; the file
#     is wholly VF-owned (it does not exist upstream).
# ---------------------------------------------------------------------------
cat > "$RECIPE_FILE" <<'TS'
import type { Recipe } from '../types.ts';

/**
 * [VF-FIX-GROK-1] Operator grok / SuperGrok subscription via the Hermes
 * xAI-OAuth proxy.
 *
 * The proxy (`hermes proxy start --provider xai`, supervised in start.sh) is a
 * localhost-only OpenAI-compatible forwarder at http://127.0.0.1:8645/v1. It
 * STRIPS the inbound Authorization header and attaches the operator's xAI OAuth
 * credential (resolved per-request from /data/.hermes/auth.json, auto-refreshing).
 * The bearer gbrain sends is therefore irrelevant — this is a KEYLESS-LOCAL
 * recipe (auth_env.required: []), modeled on the ollama / litellm-proxy recipes.
 *
 * gateway.defaultResolveAuth() sees `required.length === 0` and sends
 * `Authorization: Bearer unauthenticated`, which the proxy discards. The base
 * URL comes straight from base_url_default (cfg.base_urls['grok'] may override).
 *
 * Embeddings stay on zeroentropyai — this recipe declares only a chat
 * touchpoint. The xAI subscription bears all gbrain main-path + utility-tier
 * reasoning (chat / subagent / default / expansion / facts / takes); subscription
 * rate/usage limits apply to heavy batch jobs (atom-synthesis), which this recipe
 * does not attempt to throttle.
 */
export const grok: Recipe = {
  id: 'grok',
  name: 'Grok (xAI subscription via Hermes proxy)',
  tier: 'openai-compat',
  implementation: 'openai-compatible',
  base_url_default: 'http://127.0.0.1:8645/v1',
  auth_env: {
    required: [], // keyless: the Hermes xAI-OAuth proxy attaches the real credential and ignores the inbound bearer.
    optional: ['GROK_BASE_URL'],
  },
  touchpoints: {
    chat: {
      // openai-compat recipes accept arbitrary model ids (model-resolver.ts:
      // the model-list check is non-fatal for non-native tiers). grok-4.3 is
      // the proxy's default; list it so doctor / wizard show a sensible pick.
      models: ['grok-4.3'],
      supports_tools: true,
      // The subagent tier's enforceSubagentCapable assumes an Anthropic shape
      // and will WARN / fall back for this recipe — accepted (identical to the
      // prior openrouter:auto behavior). We still declare true: the proxy
      // forwards a tool-capable grok model and gbrain's main loop drives it.
      supports_subagent_loop: true,
      supports_prompt_cache: false,
      max_context_tokens: 256000,
      // Cost is borne by the flat-rate SuperGrok subscription, not per-token
      // billing; advisory zeros keep the pricing audit happy for openai-compat.
      cost_per_1m_input_usd: 0,
      cost_per_1m_output_usd: 0,
      price_last_verified: '2026-06-14',
    },
  },
  setup_hint: 'Routed through the Hermes xAI-OAuth proxy (hermes proxy start --provider xai, port 8645). No API key needed.',
};
TS
echo "[grok-recipe] ✓ (a) wrote keyless grok recipe -> $RECIPE_FILE"

# ---------------------------------------------------------------------------
# (b) Register the recipe in index.ts: a static import + an ALL[] array entry.
#     Anchored on the deepseek lines (an existing openai-compat recipe). Both
#     edits are idempotent.
# ---------------------------------------------------------------------------
if grep -qF "from './grok.ts'" "$INDEX"; then
  echo "[grok-recipe] ✓ (b) grok already imported in index.ts — no-op."
else
  if ! grep -qF "$ANCHOR_INDEX_IMPORT" "$INDEX"; then
    echo "[grok-recipe] ERROR: index.ts import anchor not found:" >&2
    echo "[grok-recipe]   anchor: $ANCHOR_INDEX_IMPORT" >&2
    echo "[grok-recipe] gbrain restructured recipes/index.ts. RE-POINT THIS PATCH. FAILING THE BUILD." >&2
    exit 1
  fi
  # Insert the import line immediately after the deepseek import.
  IMP=$(mktemp)
  printf "%s\n" "import { grok } from './grok.ts'; // [VF-FIX-GROK-1]" > "$IMP"
  sed -i "\@${ANCHOR_INDEX_IMPORT}@r ${IMP}" "$INDEX"
  rm -f "$IMP"
  echo "[grok-recipe] ✓ (b) added grok import to index.ts"
fi

if grep -qE '^\s*grok,\s*//\s*\[VF-FIX-GROK-1\]' "$INDEX"; then
  echo "[grok-recipe] ✓ (b) grok already in ALL[] — no-op."
else
  if ! grep -qF "$ANCHOR_INDEX_ARRAY" "$INDEX"; then
    echo "[grok-recipe] ERROR: index.ts ALL[] array anchor not found:" >&2
    echo "[grok-recipe]   anchor: $ANCHOR_INDEX_ARRAY" >&2
    echo "[grok-recipe] gbrain restructured the ALL[] recipe array. RE-POINT THIS PATCH. FAILING THE BUILD." >&2
    exit 1
  fi
  ARR=$(mktemp)
  printf "%s\n" "  grok, // [VF-FIX-GROK-1]" > "$ARR"
  sed -i "\@${ANCHOR_INDEX_ARRAY}@r ${ARR}" "$INDEX"
  rm -f "$ARR"
  echo "[grok-recipe] ✓ (b) added grok to ALL[] array"
fi

# ---------------------------------------------------------------------------
# (c) Re-point the FIX-NA-1 reroute target from openrouter:auto to the LIVE
#     DEFAULT (getChatModel()), with a guaranteed-reachable grok:grok-4.3 fallback.
#     WHY the live default and not a grok literal: gbrain has dozens of hardcoded
#     `anthropic:claude-*` UTILITY defaults; FIX-NA-1 catches them here. Pinning a
#     grok literal would leave that whole tier on grok even after the operator
#     switches the dashboard model — exactly the "task does not follow the
#     dashboard" leak class. Reading getChatModel() (== the synced live default)
#     makes the utility tier follow a switch too.
#     SAFETY (verified): (1) the ESM cycle is fine — model-resolver imports
#     getChatModel from gateway.ts and gateway.ts imports resolveRecipe from here,
#     but the call is runtime-only so bun resolves it (gbrain --version loads).
#     (2) getChatModel()->requireConfig() THROWS if the gateway isn't configured
#     yet (pre-config resolve sites: doctor, schema setup) — so it is wrapped in
#     try/catch and falls back to the grok literal. (3) the !startsWith('anthropic:')
#     guard breaks recursion (an anthropic-shaped default never re-enters this
#     branch). Idempotent: no-op once the guarded form (getChatModel) is present.
# ---------------------------------------------------------------------------
if grep -qF "$REROUTE_SENTINEL" "$RESOLVER"; then
  echo "[grok-recipe] ✓ (c) reroute already tracks the live default (getChatModel) — no-op."
else
  if ! grep -qF "VF-FIX-NA-1" "$RESOLVER"; then
    echo "[grok-recipe] ERROR: VF-FIX-NA-1 block absent from $RESOLVER." >&2
    echo "[grok-recipe]     This patch repoints the FIX-NA-1 reroute, which must run FIRST." >&2
    echo "[grok-recipe]     Ensure gbrain-no-anthropic-reroute.sh runs before this patch. FAILING THE BUILD." >&2
    exit 1
  fi
  if ! grep -qF "$ANCHOR_REROUTE_FROM" "$RESOLVER"; then
    echo "[grok-recipe] ERROR: reroute source literal not found:" >&2
    echo "[grok-recipe]   anchor: $ANCHOR_REROUTE_FROM" >&2
    echo "[grok-recipe]     gbrain-no-anthropic-reroute.sh changed its emitted target. RE-POINT THIS PATCH. FAILING THE BUILD." >&2
    exit 1
  fi
  # (c.1) add the getChatModel import (idempotent), after the errors.ts import.
  if ! grep -qF "import { getChatModel } from './gateway.ts'" "$RESOLVER"; then
    if ! grep -qF "$ANCHOR_RESOLVER_IMPORT" "$RESOLVER"; then
      echo "[grok-recipe] ERROR: resolver import anchor not found: $ANCHOR_RESOLVER_IMPORT" >&2
      echo "[grok-recipe]     gbrain restructured model-resolver.ts imports. RE-POINT THIS PATCH. FAILING THE BUILD." >&2
      exit 1
    fi
    IMP=$(mktemp)
    printf "%s\n" "import { getChatModel } from './gateway.ts'; // [VF-FIX-GROK-1] live-default reroute target (runtime-only call; ESM cycle safe)" > "$IMP"
    sed -i "\@${ANCHOR_RESOLVER_IMPORT}@r ${IMP}" "$RESOLVER"
    rm -f "$IMP"
    echo "[grok-recipe] ✓ (c.1) added getChatModel import to model-resolver.ts"
  fi
  # (c.2) replace the single reroute line with the guarded live-default block.
  #       awk fixed-string match (handles the TS punctuation) replacing the FIRST
  #       line that contains the FROM anchor with the contents of $BLK.
  BLK=$(mktemp)
  cat > "$BLK" <<'TS'
    // [VF-FIX-GROK-1] Reroute target TRACKS THE LIVE DEFAULT so a dashboard model
    // switch propagates to the hardcoded-anthropic utility tier too. try/catch:
    // getChatModel()->requireConfig() throws pre-gateway-config (doctor/schema) —
    // fall back to the guaranteed-reachable grok recipe. The !startsWith('anthropic:')
    // guard breaks reroute recursion.
    let _d = '';
    try { _d = getChatModel(); } catch { /* gateway not configured yet */ }
    return resolveRecipe(_d && !_d.startsWith('anthropic:') ? _d : 'grok:grok-4.3');
TS
  awk -v anchor="$ANCHOR_REROUTE_FROM" -v insfile="$BLK" '
    BEGIN { repl=""; while ((getline line < insfile) > 0) repl = repl line ORS }
    index($0, anchor) && !done { printf "%s", repl; done=1; next }
    { print }
    END { if (!done) exit 3 }
  ' "$RESOLVER" > "$RESOLVER.vftmp" || { echo "[grok-recipe] ERROR: (c.2) awk replace failed to find the reroute line. FAILING THE BUILD." >&2; rm -f "$BLK" "$RESOLVER.vftmp"; exit 1; }
  mv "$RESOLVER.vftmp" "$RESOLVER"
  rm -f "$BLK"
  echo "[grok-recipe] ✓ (c.2) repointed FIX-NA-1 reroute -> live default (getChatModel) with grok:grok-4.3 fallback"
fi

# ---------------------------------------------------------------------------
# Post-audit: every guarantee must now hold, or FAIL the build — never report
# success on a no-op.
# ---------------------------------------------------------------------------
if ! grep -qF "$SENTINEL" "$RECIPE_FILE"; then
  echo "[grok-recipe] ERROR: post-apply audit — $SENTINEL absent from $RECIPE_FILE. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF "from './grok.ts'" "$INDEX" || ! grep -qE '^\s*grok,\s*//\s*\[VF-FIX-GROK-1\]' "$INDEX"; then
  echo "[grok-recipe] ERROR: post-apply audit — grok not fully registered in index.ts. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF "$REROUTE_SENTINEL" "$RESOLVER"; then
  echo "[grok-recipe] ERROR: post-apply audit — reroute does not track the live default (getChatModel guarded form absent). FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF "import { getChatModel } from './gateway.ts'" "$RESOLVER"; then
  echo "[grok-recipe] ERROR: post-apply audit — getChatModel import missing from model-resolver.ts (guarded reroute would not compile). FAILING THE BUILD." >&2
  exit 1
fi
# The guaranteed-reachable fallback literal must remain present.
if ! grep -qF "'grok:grok-4.3'" "$RESOLVER"; then
  echo "[grok-recipe] ERROR: post-apply audit — grok:grok-4.3 fallback literal absent from the reroute. FAILING THE BUILD." >&2
  exit 1
fi
# Defensive: the openrouter:auto literal must be GONE from the resolver (else
# the repoint did not land and the brain would still route to openrouter).
if grep -qF "resolveRecipe('openrouter:auto')" "$RESOLVER"; then
  echo "[grok-recipe] ERROR: post-apply audit — openrouter:auto reroute literal still present after repoint. FAILING THE BUILD." >&2
  exit 1
fi
echo "[grok-recipe] ✓ applied: keyless grok recipe registered; FIX-NA-1 reroute -> live default (getChatModel) with grok:grok-4.3 fallback (xAI subscription via Hermes proxy)."
echo "[grok-recipe] done."
