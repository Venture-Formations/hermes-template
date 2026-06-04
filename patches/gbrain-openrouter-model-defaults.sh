#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-openrouter-model-defaults.sh
#
# WHY THIS EXISTS
# gbrain hardcodes NATIVE `anthropic:` model strings as the default for ~8
# LLM touchpoints (fact dedup classifier, page synopsis, contextual-retrieval,
# takes bootstrap, contradiction judge, brainstorm, propose/grade takes, and
# the gateway chat/expansion defaults). A model string's provider PREFIX picks
# the API key:
#     anthropic:claude-haiku-4-5            -> Anthropic API  (ANTHROPIC_API_KEY)
#     openrouter:anthropic/claude-haiku-4.5 -> OpenRouter      (OPENROUTER_API_KEY)  <- same model
# This deployment has only OPENROUTER_API_KEY + OPENAI_API_KEY (no Anthropic
# key). So every code path that falls through to a hardcoded `anthropic:`
# default throws inside chat() and is swallowed silently (e.g. facts/takes
# extractors return [] / continue, fact-dedup degrades to cosine_fallback).
# Setting `models.default` / `chat_model` only fixes the paths that READ config;
# these hardcoded literals have no config knob, so we rewrite the literals to
# their OpenRouter-routed equivalents (same model, same tier — haiku->haiku,
# sonnet->sonnet) so the whole brain runs on the OpenRouter key.
#
# This is the ONE place gbrain *core* is modified (see hermes-template and
# hermes-workspace CLAUDE.md — the "never modify gbrain core" rule has this
# documented exception). It is applied at Docker BUILD time (right after the
# gbrain install) so it is baked into the image and re-applied on every
# GBRAIN_REF bump. It is also safe to run on a live container.
#
# ⚠️ VALIDATE ON EVERY gbrain UPGRADE: gbrain may rename a model id, move a
# default, or add a new hardcoded `anthropic:` touchpoint. After a GBRAIN_REF
# bump, re-run this script and confirm the post-patch audit reports 0 remaining
# `anthropic:claude-*` MODEL defaults. If the audit is non-zero, add the new
# literal to the REPLACEMENTS list below. (The native `anthropic:messages`
# rate-limit key is intentionally NOT a model and must stay untouched.)
#
# Idempotent: re-running after a successful patch is a no-op.
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolve the gbrain source tree across build + runtime layouts.
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[gbrain-patch] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
echo "[gbrain-patch] target: $GBRAIN_SRC"

# De-pinned: every previously-hardcoded tier now routes through openrouter:auto
# so gbrain is fully DYNAMIC (no model is pinned in source). This mirrors the
# Hermes dashboard pattern (main model = openrouter/auto, all auxiliary tasks =
# "auto / use main model") — one dynamic OpenRouter auto-router everywhere,
# tuned via OpenRouter provider preferences rather than baked-in model ids.
# (haiku/sonnet/opus tier distinctions collapse into auto by design.)
OR_HAIKU='openrouter:auto'
OR_SONNET='openrouter:auto'
OR_OPUS='openrouter:auto'

# Exact-string rewrites. Order matters for haiku: the dated literal must be
# rewritten before the bare one so the bare rule does not corrupt the suffix.
# Every pattern is a QUOTED model default — none of these strings appear in the
# provider recipes (which list bare ids in arrays) or as the `anthropic:messages`
# rate key, so a tree-wide replace is safe.
apply() {  # apply <find> <replace>
  # -l lists files containing the literal; only touch those (keeps output tight).
  # `|| true`: no-match (grep exit 1) is NORMAL — a pattern may be absent on a
  # given gbrain version or on an idempotent re-run. Under `set -euo pipefail`
  # an unguarded `grep | while` would abort the whole script (and the build).
  local files
  files=$(grep -rl --include='*.ts' -F "$1" "$GBRAIN_SRC" 2>/dev/null || true)
  [ -z "$files" ] && return 0
  while IFS= read -r f; do
    # `@` is the sed delimiter (never appears in our strings); the find side
    # has no regex metachars and the replace side has no `&`/`\`, so this is
    # a literal substitution.
    sed -i "s@$1@$2@g" "$f"
    echo "[gbrain-patch]   $f"
  done <<< "$files"
}

echo "[gbrain-patch] rewriting native-anthropic model defaults -> OpenRouter..."
apply "'anthropic:claude-haiku-4-5-20251001'" "'${OR_HAIKU}'"
apply "'anthropic:claude-haiku-4-5'"          "'${OR_HAIKU}'"
apply "'anthropic:claude-sonnet-4-6'"         "'${OR_SONNET}'"
apply "'anthropic:claude-opus-4-7'"           "'${OR_OPUS}'"
# Bare ids used as `?? '<id>'` defaults (propose-takes / grade-takes /
# book-mirror). The `?? '` prefix guarantees we only hit default expressions,
# never recipe arrays or pricing-table keys.
apply "?? 'claude-sonnet-4-6'"                 "?? '${OR_SONNET}'"
apply "?? 'claude-haiku-4-5'"                  "?? '${OR_HAIKU}'"
apply "?? 'claude-opus-4-7'"                   "?? '${OR_OPUS}'"

# Post-patch audit: any quoted `anthropic:claude-*` model default, or a bare
# `?? 'claude-*'` default, still present is a NEW touchpoint gbrain introduced.
echo "[gbrain-patch] audit — remaining native-anthropic model defaults:"
REMAIN=$(grep -rnE "'anthropic:claude-[a-z0-9.-]+'|\?\? '(anthropic:)?claude-[a-z0-9.-]+'" \
           --include='*.ts' "$GBRAIN_SRC" 2>/dev/null \
           | grep -v '/ai/recipes/' || true)
if [ -n "$REMAIN" ]; then
  echo "$REMAIN" | sed 's/^/[gbrain-patch]   LEFTOVER: /'
  echo "[gbrain-patch] ⚠️  $(echo "$REMAIN" | wc -l | tr -d ' ') leftover default(s) — update REPLACEMENTS in this script." >&2
else
  echo "[gbrain-patch] ✓ 0 remaining native-anthropic model defaults."
fi
echo "[gbrain-patch] done."
