#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-grok-budget-unmetered.probe.sh   (still_needed_probe for FIX-GROK-BUDGET-1)
#
# Answers, per upgrade, "did this gbrain version make our grok-as-$0 BudgetTracker
# allowlist unnecessary, so the patch can be retired?" — run by the WS4 CI dry-run
# against the VANILLA (un-patched) candidate tree, and by verify-upgrade.sh
# on-container.
#
# The patch exists because gbrain's BudgetTracker.lookupPricing() hard-fails
# ("TX2 no_pricing") on a --max-cost-capped call when the active model id is
# absent from the pricing maps, and the operator's grok recipe (flat-rate OAuth
# subscription) is intentionally unpriced. The patch adds grok to a
# FREE_SUBSCRIPTION_CHAT_PROVIDERS allowlist that returns $0, mirroring gbrain's
# own FREE_LOCAL_* sets.
#
# It is OBSOLETE only if upstream gbrain itself makes a capped grok call no longer
# no_pricing-fail, i.e. ANY of:
#   (1) a grok/xai key becomes reachable in the pricing maps the chat lookup uses
#       (CANONICAL_PRICING / anthropic-pricing.ts gains a grok/xai entry), OR
#   (2) gbrain adds grok/xai to one of its OWN free-provider sets in
#       budget-tracker.ts (a non-VF FREE_*_PROVIDERS Set containing 'grok'/'xai'), OR
#   (3) the long-standing "recipe-cost-driven resolution" TODO lands so the
#       recipe's advisory cost_per_1m_*_usd:0 actually feeds lookupPricing.
# Any of these is a human-reviewed retirement (we'd route via the native path).
#
# Exit codes (the harness contract for every *.probe.sh):
#   0 = STILL NEEDED  — keep the patch
#   1 = OBSOLETE      — upstream made it redundant; recommend retirement
#   2 = UNKNOWN       — could not determine; escalate for manual review
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
if [ -z "$GBRAIN_SRC" ]; then
  echo "[grok-budget-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

BT="$GBRAIN_SRC/core/budget/budget-tracker.ts"
PRICING="$GBRAIN_SRC/core/model-pricing.ts"
ANTH="$GBRAIN_SRC/core/anthropic-pricing.ts"
if [ ! -f "$BT" ]; then
  echo "[grok-budget-probe] UNKNOWN: budget-tracker.ts not found at $BT." >&2
  exit 2
fi

# (1) Does upstream now price grok/xai in either pricing source? (case-insensitive
#     grep for a grok/xai pricing key, ignoring our own VF marker lines.)
PRICED=0
for f in "$PRICING" "$ANTH"; do
  [ -f "$f" ] || continue
  if grep -v 'VF-FIX-GROK' "$f" | grep -qiE "(grok|xai)[^a-z]*('|\"|:).*(input|output|[0-9])" ; then
    # Confirm it really looks like a pricing key/value, not an incidental comment.
    if grep -v 'VF-FIX-GROK' "$f" | grep -qiE "['\"](grok|xai)[:/-]" ; then
      PRICED=1
    fi
  fi
done

# (2) Does upstream's budget-tracker.ts put grok/xai in a NON-VF free-provider set?
#     Strip our VF block first, then look for a FREE_* Set literal containing grok/xai.
UPSTREAM_FREE=0
STRIPPED=$(grep -v 'VF-FIX-GROK-BUDGET-1' "$BT" 2>/dev/null || true)
if printf '%s\n' "$STRIPPED" | grep -qiE "FREE_[A-Z_]*PROVIDERS" ; then
  # crude: any free-provider Set body line that is just 'grok' or 'xai'
  if printf '%s\n' "$STRIPPED" | grep -qiE "^\s*'(grok|xai)'," ; then
    UPSTREAM_FREE=1
  fi
fi

# (3) Did the recipe-cost-driven-resolution TODO land? Heuristic: the TODO comment
#     is GONE *and* lookupPricing now references recipe cost fields.
RECIPE_COST=0
if ! grep -qiF "recipe-cost-driven resolution" "$BT" 2>/dev/null; then
  if grep -qiE "cost_per_1m|recipe.*cost|touchpoint.*cost" "$BT" 2>/dev/null; then
    RECIPE_COST=1
  fi
fi

echo "[grok-budget-probe] signals: upstream_priced=$PRICED upstream_free_set=$UPSTREAM_FREE recipe_cost_resolution=$RECIPE_COST"

if [ "$PRICED" -eq 1 ] || [ "$UPSTREAM_FREE" -eq 1 ] || [ "$RECIPE_COST" -eq 1 ]; then
  echo "[grok-budget-probe] OBSOLETE: upstream now makes a capped grok call price/resolve natively — review and retire FIX-GROK-BUDGET-1."
  exit 1
fi

echo "[grok-budget-probe] STILL NEEDED: grok remains unpriced and absent from any upstream free-provider set; a --max-cost-capped grok call still TX2 no_pricing-fails without this allowlist."
exit 0
