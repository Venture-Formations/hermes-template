#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-grok-recipe.probe.sh   (still_needed_probe for FIX-GROK-1)
#
# Answers, per upgrade, "did this gbrain version make our grok-via-Hermes-proxy
# recipe unnecessary, so the patch can be retired?" — run by the WS4 CI dry-run
# against the VANILLA (un-patched) candidate tree, and by verify-upgrade.sh
# on-container.
#
# The patch exists because gbrain ships NO recipe that routes to the operator's
# grok / SuperGrok subscription through the localhost Hermes xAI-OAuth proxy
# (http://127.0.0.1:8645/v1). gbrain HAS keyless-local openai-compat recipes
# (ollama, litellm) but none pinned at the Hermes proxy as a `grok`/`xai`
# provider. The patch is OBSOLETE only if upstream adds such a recipe (a `grok`
# or `xai` openai-compat recipe whose base URL is the local Hermes proxy) — at
# which point we'd route via the native recipe instead of injecting our own.
#
# This is an ADD-ONLY recipe + a repoint of FIX-NA-1, so "still needed" is the
# normal answer; it only goes obsolete if the operator abandons grok routing
# (a human decision, NOT detectable here) or upstream ships the same recipe.
#
# Exit codes (the harness contract for every *.probe.sh):
#   0 = STILL NEEDED  — keep the patch
#   1 = OBSOLETE      — upstream shipped an equivalent; recommend retirement
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
  echo "[grok-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

RECIPES_DIR="$GBRAIN_SRC/core/ai/recipes"
INDEX="$RECIPES_DIR/index.ts"

if [ ! -f "$INDEX" ]; then
  echo "[grok-probe] UNKNOWN: recipes/index.ts not found at $INDEX." >&2
  exit 2
fi

# Signal: does upstream ship a NON-VF grok/xai openai-compat recipe pointing at
# the local Hermes proxy (127.0.0.1:8645)? We look for an upstream recipe file
# (id grok or xai) that is NOT ours (our file carries the VF-FIX-GROK-1 marker).
UPSTREAM_GROK=0
for cand in "$RECIPES_DIR/grok.ts" "$RECIPES_DIR/xai.ts"; do
  [ -f "$cand" ] || continue
  if ! grep -qF 'VF-FIX-GROK-1' "$cand" 2>/dev/null; then
    # An upstream-authored grok/xai recipe exists. If it targets the Hermes
    # local proxy, our injection is redundant.
    if grep -qE '127\.0\.0\.1:8645|localhost:8645' "$cand" 2>/dev/null; then
      UPSTREAM_GROK=1
    fi
  fi
done

echo "[grok-probe] upstream grok/xai recipe targeting the Hermes proxy present: $UPSTREAM_GROK"

if [ "$UPSTREAM_GROK" -eq 1 ]; then
  echo "[grok-probe] OBSOLETE: upstream ships a grok/xai openai-compat recipe pointed at the Hermes proxy — review and retire FIX-GROK-1 (route via the native recipe)."
  exit 1
fi

echo "[grok-probe] STILL NEEDED: no upstream grok/xai recipe targets the Hermes xAI-OAuth proxy; our keyless recipe + FIX-NA-1 repoint remains required."
exit 0
