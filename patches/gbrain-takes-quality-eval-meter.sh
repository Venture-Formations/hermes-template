#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-takes-quality-eval-meter.sh   (VF FIX-TQM-1)
#
# WHY THIS EXISTS — the `gbrain eval takes-quality` METER is broken two ways,
# both verified in src/core/takes-quality-eval/runner.ts:
#   (P2) DEFAULT_MODEL_PANEL (L36-40) = [openai:gpt-4o, anthropic:claude-opus-4-7,
#        google:gemini-1.5-pro]. On THIS deployment only the anthropic id reroutes
#        to grok ($0) via FIX-NA-1; openai/google need native keys we don't have,
#        so a BARE `gbrain eval takes-quality run` gets <2 successful models
#        (MIN_SUCCESSES_FOR_VERDICT=2) → verdict INCONCLUSIVE with empty scores,
#        AND a default run would bill the native OPENAI_API_KEY + Google key
#        (same native-billing leak class as FIX-CME-1). The brain's weekly
#        eval-takes-quality.sh wrapper already overrides --models with an
#        all-anthropic panel, but the BUILT-IN default must be billing-safe and
#        verdict-capable so any bare run (operator, ad-hoc) works at $0.
#   (P1) The sample query (sampleTakesAsText, L92-97) has NO `active` filter in
#        either the slugPrefix branch (L81) or the default branch (L94) — it
#        scores EVERY take row including struck (active=false) / superseded ones.
#        Every other reader filters `WHERE active` (searchTakes, vector recall,
#        rollups). This is the substrate that makes the SAFE, reversible
#        supersede/soft-strike cleanup path actually remove a take from the eval
#        sample (today a no-op: 0 inactive rows, but a latent correctness bug and
#        the prerequisite for any future supersede-based cleanup).
#
# WHAT THIS PATCH DOES (runner.ts only; pure read-path/config; ZERO brain mutation):
#   P2: repoint DEFAULT_MODEL_PANEL to 3 DISTINCT anthropic ids (all reroute to
#       grok via FIX-NA-1, $0, ≥2 successes → real PASS/FAIL).
#   P1: add `AND t.active` to the slugPrefix branch and `WHERE t.active` to the
#       default branch of the eval sampler.
# Validated live 2026-06-16: pre-patch bare run = INCONCLUSIVE; post-patch bare
# run returns FAIL 6.3 with 3/3 anthropic models scoring, active-filtered.
#
# ANCHORS (each present EXACTLY ONCE in runner.ts):
#   P2: the 3-line native DEFAULT_MODEL_PANEL block.
#   P1a: `WHERE p.slug LIKE $${params.length}` (slugPrefix branch).
#   P1b: `${where || 'JOIN pages p ON p.id = t.page_id'}` (default branch).
#
# gbrain *core* modification: build-time, baked, re-applied per GBRAIN_REF bump,
# idempotent (no-op if the FIX-TQM-1 sentinel is present), FAILS THE BUILD LOUDLY
# (old container keeps serving) on anchor drift. NOT filed upstream (operator
# decision 2026-06-16) — VF fork patch. See gbrain-takes-quality-eval-meter.meta.yml.
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
  echo "[gbrain-patch:tqm-1] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

RUNNER="$GBRAIN_SRC/core/takes-quality-eval/runner.ts"
if [ ! -f "$RUNNER" ]; then
  echo "[gbrain-patch:tqm-1] ERROR: $RUNNER not found — gbrain moved the takes-quality eval runner. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi
echo "[gbrain-patch:tqm-1] target: $RUNNER"

SENTINEL="// FIX-TQM-1"
if grep -qF "$SENTINEL" "$RUNNER"; then
  echo "[gbrain-patch:tqm-1] ✓ already applied (FIX-TQM-1 sentinel present); no-op."
  exit 0
fi

# --- edit helper: exact one-line/one-block replace with count assertion -----
edit_once() {
  local file="$1" old="$2" new="$3" label="$4"
  OLD="$old" NEW="$new" LABEL="$label" python3 - "$file" <<'PYEOF'
import os, sys
path = sys.argv[1]; old=os.environ['OLD']; new=os.environ['NEW']; label=os.environ['LABEL']
s = open(path, encoding='utf-8').read()
n = s.count(old)
if n != 1:
    sys.stderr.write(f"[gbrain-patch:tqm-1] ERROR: anchor [{label}] found {n} times (need exactly 1). gbrain changed the runner. RE-POINT. FAILING THE BUILD.\n")
    sys.exit(1)
open(path,'w',encoding='utf-8').write(s.replace(old,new))
PYEOF
}

# P2 — default panel -> 3 distinct anthropic ids (sentinel rides the first line).
P2_OLD="  'openai:gpt-4o',
  'anthropic:claude-opus-4-7',
  'google:gemini-1.5-pro',"
P2_NEW="  'anthropic:claude-opus-4-7', ${SENTINEL} (hermes-template build patch): default panel repointed to 3 DISTINCT anthropic ids so a bare \`gbrain eval takes-quality run\` reroutes entirely to grok (\$0) via FIX-NA-1 and gets >=2 successes (real PASS/FAIL, not INCONCLUSIVE) instead of billing native OpenAI/Google keys. The eval-takes-quality.sh wrapper's --models override is unaffected. See gbrain-takes-quality-eval-meter.meta.yml.
  'anthropic:claude-sonnet-4-6',
  'anthropic:claude-haiku-4-5',"
edit_once "$RUNNER" "$P2_OLD" "$P2_NEW" "P2.default-panel"

# P1a — slugPrefix branch active filter.
edit_once "$RUNNER" 'WHERE p.slug LIKE $${params.length}`' 'WHERE p.slug LIKE $${params.length} AND t.active`' "P1a.slugPrefix-active"

# P1b — default branch active filter.
edit_once "$RUNNER" "\${where || 'JOIN pages p ON p.id = t.page_id'}" "\${where || 'JOIN pages p ON p.id = t.page_id WHERE t.active'}" "P1b.default-active"

# --- POST-AUDIT ------------------------------------------------------------
if ! grep -qF "$SENTINEL" "$RUNNER"; then
  echo "[gbrain-patch:tqm-1] ERROR: post-apply audit — sentinel absent. FAILING THE BUILD." >&2; exit 1
fi
if grep -qF "'openai:gpt-4o'," "$RUNNER" || grep -qF "'google:gemini-1.5-pro'," "$RUNNER"; then
  echo "[gbrain-patch:tqm-1] ERROR: post-apply audit — a native openai:/google: default-panel id remains. FAILING THE BUILD." >&2; exit 1
fi
if ! grep -qF "WHERE t.active'}" "$RUNNER" || ! grep -qF "AND t.active\`" "$RUNNER"; then
  echo "[gbrain-patch:tqm-1] ERROR: post-apply audit — eval sampler active-filter not present in both branches. FAILING THE BUILD." >&2; exit 1
fi
echo "[gbrain-patch:tqm-1] ✓ applied: default panel = 3 anthropic ids (\$0 grok, no INCONCLUSIVE); eval sampler filters WHERE active in both branches."
echo "[gbrain-patch:tqm-1] done."
