#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-grok-budget-unmetered.sh   (VF FIX-GROK-BUDGET-1)
#
# WHY THIS EXISTS
# We route the gbrain knowledge engine's LLM calls through the operator's
# grok / SuperGrok subscription via the Hermes xAI-OAuth proxy (FIX-GROK-1).
# That subscription is FLAT-RATE: zero marginal per-token dollar cost. But
# gbrain's BudgetTracker (src/core/budget/budget-tracker.ts) HARD-FAILS
# ("TX2 no_pricing") whenever a `--max-cost` cap is set AND the active model id
# is absent from the pricing maps — and `grok:grok-4.3` is intentionally absent
# (no marginal $). `gbrain brainstorm` is the live victim: its orchestrator
# FORCES `maxCostUsd ?? 5` and the CLI rejects `--max-cost 0`, so there is NO
# bypass — every brainstorm run TX2-fails on grok. Any future `--max-cost`-capped
# phase routed to grok (conversation_facts_backfill, enrich_thin, skillopt,
# autopilot.auto_drain — all currently disabled) would fail identically.
#
# WHY NOT "ADD A PRICE" (the obvious fix — rejected after a multi-discipline review):
#   * ANTHROPIC_PRICING (what the chat lookup reads) is a DERIVED, anthropic-only
#     view (Object.fromEntries over CANONICAL_PRICING filtered to keys starting
#     `anthropic:`), and its file header forbids hand-editing. A `grok:grok-4.3`
#     canonical key is filtered OUT and never reaches lookupPricing's chat path —
#     so a CANONICAL/anthropic-pricing entry is MECHANICALLY UNREACHABLE without
#     also re-routing budget-tracker through canonicalLookup (a behavior change to
#     a security-sensitive accounting primitive for ALL non-anthropic models).
#   * A real dollar price is also economically wrong: on a flat-rate sub the $5
#     cap becomes a hard wall that would falsely abort long-but-free runs. And it
#     buys no runaway protection that we lose here: the brainstorm orchestrator's
#     OWN volume guards (estimateCost + runningUsd>cap) compute cost via
#     canonicalLookup(model) ?? Sonnet {3,15} — a path INDEPENDENT of
#     BudgetTracker.lookupPricing — so the token-VOLUME backstop stays fully live.
#
# WHAT IT DOES (two atomic edits to budget-tracker.ts, one smoke gate):
#   (a) adds a `FREE_SUBSCRIPTION_CHAT_PROVIDERS = new Set(['grok'])` const,
#       sibling to the upstream FREE_LOCAL_RERANK_PROVIDERS / FREE_LOCAL_EMBED_PROVIDERS
#       sets that already encode "this provider's tokens are unmetered -> price $0".
#   (b) in lookupPricing(), after the two ANTHROPIC_PRICING misses and BEFORE the
#       existing rerank free-provider clause, returns {input:0,output:0} for kind
#       chat|rerank when the provider half is in that set. Matched on the PROVIDER
#       half ('grok', our recipe id) so grok-4.3 -> grok-4.4 needs no edit. Paid
#       providers (anthropic:claude-*, etc.) are unaffected — they price earlier.
#
# This is the honest representation: a flat-rate OAuth subscription is unmetered,
# exactly like the local-inference FREE_LOCAL_* providers gbrain already zeroes.
#
# Applied at Docker BUILD time after the gbrain install (and after the grok
# recipe patch — logical grouping; no hard dependency, different file); re-applied
# on every GBRAIN_REF bump; idempotent; safe to re-run on a live container. FAILS
# THE BUILD LOUDLY (old container keeps serving) if an anchor moved, so it gets
# re-pointed (never a silent no-op). See UPGRADING_GBRAIN.md.
# ---------------------------------------------------------------------------
set -euo pipefail

SENTINEL='VF-FIX-GROK-BUDGET-1'

# Resolve the gbrain source tree across build + runtime layouts.
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[grok-budget] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
BT="$GBRAIN_SRC/core/budget/budget-tracker.ts"
echo "[grok-budget] gbrain src: $GBRAIN_SRC"

if [ ! -f "$BT" ]; then
  echo "[grok-budget] ERROR: $BT missing — gbrain moved/renamed budget-tracker.ts. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi

# Anchors we must find before mutating (LOUD on drift, never a silent skip).
# A_EMBED_HEAD: EDIT 1 inserts the new const right AFTER this set's closing `]);`
#               (grouping it with its FREE_LOCAL_* siblings — its natural home).
# A_CLAUSE    : EDIT 2 inserts the new chat/rerank clause immediately BEFORE this
#               line (so providerId is already in scope from the
#               splitProviderModelId destructure above it). This literal is ALSO
#               the meta `anchor` (--check asserts it is present in this .sh body).
# A_SIBLING   : sanity — the upstream free-provider pattern we mirror is present.
# A_DESTRUCT  : sanity — providerId is in scope where EDIT 2 lands.
A_EMBED_HEAD="const FREE_LOCAL_EMBED_PROVIDERS: ReadonlySet<string> = new Set(["
A_CLAUSE="if (kind === 'rerank' && providerId && FREE_LOCAL_RERANK_PROVIDERS.has(providerId)) {"
A_SIBLING="const FREE_LOCAL_RERANK_PROVIDERS: ReadonlySet<string> = new Set(["
A_DESTRUCT="const { provider: providerId, model: modelTail } = splitProviderModelId(modelId);"

for a in "$A_EMBED_HEAD" "$A_CLAUSE" "$A_SIBLING" "$A_DESTRUCT"; do
  if ! grep -qF "$a" "$BT"; then
    echo "[grok-budget] ERROR: anchor not found in $BT:" >&2
    echo "[grok-budget]   anchor: $a" >&2
    echo "[grok-budget] gbrain restructured budget-tracker.ts lookupPricing(). RE-POINT THIS PATCH. FAILING THE BUILD." >&2
    exit 1
  fi
done

# Insert the contents of $2 (a file) immediately BEFORE the first line of $1
# containing the fixed-string anchor $3. Fixed-string match (index), so TS
# punctuation in the anchor is safe. Fails (exit 3) if the anchor is absent.
insert_before() {
  local file="$1" insfile="$2" anchor="$3"
  awk -v anchor="$anchor" -v insfile="$insfile" '
    BEGIN { ins=""; while ((getline line < insfile) > 0) ins = ins line ORS }
    !done && index($0, anchor) { printf "%s", ins; done=1 }
    { print }
    END { if (!done) exit 3 }
  ' "$file" > "$file.vftmp"
  mv "$file.vftmp" "$file"
}

# Insert the contents of $2 (a file) immediately AFTER the `]);` line that closes
# the Set literal whose declaration contains the fixed-string anchor $3. Used to
# drop the new const right after a sibling FREE_LOCAL_* set. Fails (exit 3) if
# the anchor (or its closing `]);`) is absent.
insert_after_set() {
  local file="$1" insfile="$2" anchor="$3"
  awk -v anchor="$anchor" -v insfile="$insfile" '
    BEGIN { ins=""; while ((getline line < insfile) > 0) ins = ins line ORS }
    { print }
    index($0, anchor) { armed=1 }
    armed && !done && $0 ~ /^\]\);[[:space:]]*$/ { printf "%s", ins; done=1; armed=0 }
    END { if (!done) exit 3 }
  ' "$file" > "$file.vftmp"
  mv "$file.vftmp" "$file"
}

# ---------------------------------------------------------------------------
# Idempotency: if the sentinel is already present, both edits landed — no-op.
# ---------------------------------------------------------------------------
if grep -qF "$SENTINEL" "$BT"; then
  echo "[grok-budget] ✓ $SENTINEL already present in budget-tracker.ts — no-op."
else
  # -- EDIT 1: the FREE_SUBSCRIPTION_CHAT_PROVIDERS const, before lookupPricing().
  if grep -qF "FREE_SUBSCRIPTION_CHAT_PROVIDERS" "$BT"; then
    echo "[grok-budget] ✓ (a) FREE_SUBSCRIPTION_CHAT_PROVIDERS already present — no-op."
  else
    CONST=$(mktemp)
    cat > "$CONST" <<'TS'

/**
 * [VF-FIX-GROK-BUDGET-1] Chat/rerank providers whose tokens are billed by a
 * FLAT-RATE OAuth subscription (the Hermes xAI-OAuth proxy -> operator
 * grok/SuperGrok), NOT per-token. Sibling to the FREE_LOCAL_*_PROVIDERS sets
 * above; matched on the provider half of `provider:model`. Without this, a
 * `--max-cost`-capped chat phase (brainstorm forces maxCostUsd ?? 5 and its CLI
 * rejects `--max-cost 0`, so there is no bypass) TX2 no_pricing-hard-fails on
 * grok, which is intentionally absent from the pricing maps (no marginal $).
 * Returning {0,0} satisfies the cap; the brainstorm orchestrator's own
 * canonicalLookup + Sonnet-proxy token-VOLUME guards (a separate code path)
 * stay fully live.
 */
const FREE_SUBSCRIPTION_CHAT_PROVIDERS: ReadonlySet<string> = new Set([
  'grok',
]);
TS
    insert_after_set "$BT" "$CONST" "$A_EMBED_HEAD"
    rm -f "$CONST"
    echo "[grok-budget] ✓ (a) inserted FREE_SUBSCRIPTION_CHAT_PROVIDERS const"
  fi

  # -- EDIT 2: the chat/rerank $0 clause, before the existing rerank clause.
  if grep -qF "kind === 'chat' || kind === 'rerank'" "$BT"; then
    echo "[grok-budget] ✓ (b) chat/rerank free-subscription clause already present — no-op."
  else
    CLAUSE=$(mktemp)
    cat > "$CLAUSE" <<'TS'
  // [VF-FIX-GROK-BUDGET-1] Flat-rate-subscription chat/rerank providers (grok
  // via the Hermes xAI-OAuth proxy) are unmetered: price at $0 so a --max-cost
  // cap does not no_pricing-hard-fail. providerId is in scope from the
  // splitProviderModelId destructure above. Paid providers are unaffected (they
  // are priced by the ANTHROPIC_PRICING lookups earlier in this function).
  if ((kind === 'chat' || kind === 'rerank') && providerId && FREE_SUBSCRIPTION_CHAT_PROVIDERS.has(providerId)) {
    return { input: 0, output: 0 };
  }
TS
    insert_before "$BT" "$CLAUSE" "$A_CLAUSE"
    rm -f "$CLAUSE"
    echo "[grok-budget] ✓ (b) inserted chat/rerank free-subscription clause"
  fi
fi

# ---------------------------------------------------------------------------
# Post-audit: every guarantee must now hold, or FAIL the build — never report
# success on a no-op. (The Dockerfile `gbrain --version` RUN after this patch is
# the TS compile/load gate that catches any syntax breakage.)
# ---------------------------------------------------------------------------
if ! grep -qF "$SENTINEL" "$BT"; then
  echo "[grok-budget] ERROR: post-apply audit — $SENTINEL absent from $BT. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF "FREE_SUBSCRIPTION_CHAT_PROVIDERS: ReadonlySet<string> = new Set([" "$BT"; then
  echo "[grok-budget] ERROR: post-apply audit — FREE_SUBSCRIPTION_CHAT_PROVIDERS const not landed. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF "kind === 'chat' || kind === 'rerank'" "$BT"; then
  echo "[grok-budget] ERROR: post-apply audit — chat/rerank free-subscription clause not landed. FAILING THE BUILD." >&2
  exit 1
fi
# Defensive: the existing rerank free-provider clause must SURVIVE (we insert
# before it, never replace it) so llama-server-reranker stays $0.
if ! grep -qF "$A_CLAUSE" "$BT"; then
  echo "[grok-budget] ERROR: post-apply audit — existing rerank free-provider clause was lost. FAILING THE BUILD." >&2
  exit 1
fi
echo "[grok-budget] ✓ applied: grok provider treated as \$0 (flat-rate subscription) in BudgetTracker.lookupPricing for chat|rerank; paid providers unaffected."
echo "[grok-budget] done."
