#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-takes-classifier-quality.sh   (VF FIX-TQC-1)
#
# WHY — gbrain-core CLASSIFIER_SYSTEM (src/core/extract-takes-from-pages.ts:24-38)
# is the LLM take-extraction prompt. The takes-quality eval rubric (rubric.ts)
# flags three contract gaps the prompt never states:
#   - kind_classification: no conservatism tiebreak + a "fact" example that
#     invites verifiable-sounding OPINIONS to be kinded fact (e.g. "95% of AI
#     pilots fail" stored as fact w=1.0).
#   - weight_calibration: NO weight-magnitude guidance at all → over-confident
#     facts (judge: "lower default fact weights to 0.8 max unless quoted").
#   - signal_density (worst dim): the only exclusion ("Skip pure narrative,
#     questions, definitions, pure quotes") names NONE of the rubric trivia
#     (handles, follower/repo counts, team rosters, restated bio, generic praise).
#
# SCOPE NOTE (verified): CLASSIFIER_SYSTEM only runs on ALLOWED_PAGE_TYPES
# (concept/atom/lore/briefing/writing/originals) — ~11% of the corpus (~53 of
# 5185 takes). The other 99% are fence-projected via FIX-TK-2 (company/person
# pages) and are NOT governed by this prompt. So this patch improves the
# LLM-extracted path's FUTURE takes; it is NOT a corpus-wide score-mover. The
# dominant attribution defect (holder=system) lives in FIX-TK-2 route.ts
# resolveSpeaker and is handled separately.
#
# WHAT — three exact-once edits to the CLASSIFIER_SYSTEM template literal:
#   (1) replace the Kind taxonomy block with a CONSERVATIVE version + append
#       weight-magnitude rules; (2) replace the Skip line with the expanded
#       named-trivia exclusion. FIX-TK-2 also edits this file but consumes the
#       addTakesBatch flush / ALLOWED_PAGE_TYPES / loop body — NOT the prompt
#       literal — so the anchors do not overlap. Order this patch AFTER FIX-TK-2.
#
# gbrain *core* modification: build-time, baked, re-applied per GBRAIN_REF bump,
# idempotent (no-op if FIX-TQC-1 sentinel present), FAILS THE BUILD LOUDLY (old
# container keeps serving) on anchor drift. NOT filed upstream (operator decision
# 2026-06-16) — VF fork patch. See gbrain-takes-classifier-quality.meta.yml.
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
  echo "[gbrain-patch:tqc-1] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

CMD="$GBRAIN_SRC/core/extract-takes-from-pages.ts"
if [ ! -f "$CMD" ]; then
  echo "[gbrain-patch:tqc-1] ERROR: $CMD not found — gbrain moved the take extractor. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi
echo "[gbrain-patch:tqc-1] target: $CMD"

SENTINEL="// FIX-TQC-1"
if grep -qF "$SENTINEL" "$CMD"; then
  echo "[gbrain-patch:tqc-1] ✓ already applied (FIX-TQC-1 sentinel present); no-op."
  exit 0
fi

edit_once() {
  local file="$1" old="$2" new="$3" label="$4"
  OLD="$old" NEW="$new" LABEL="$label" python3 - "$file" <<'PYEOF'
import os, sys
path=sys.argv[1]; old=os.environ['OLD']; new=os.environ['NEW']; label=os.environ['LABEL']
s=open(path,encoding='utf-8').read(); n=s.count(old)
if n!=1:
    sys.stderr.write(f"[gbrain-patch:tqc-1] ERROR: anchor [{label}] found {n} times (need exactly 1). gbrain changed CLASSIFIER_SYSTEM. RE-POINT. FAILING THE BUILD.\n")
    sys.exit(1)
open(path,'w',encoding='utf-8').write(s.replace(old,new))
PYEOF
}

# Edit 1 — conservative Kind taxonomy + appended weight rules. Sentinel rides here.
KIND_OLD='Kind taxonomy:
  - fact: verifiable as true/false (e.g. "X raised $5M in Mar 2024")
  - take: a stated opinion that could be wrong (e.g. "X is undervalued")
  - bet:  a forward-looking prediction (e.g. "X will IPO in 2026")
  - hunch: a low-confidence gut feeling (e.g. "Y feels overstretched")'
KIND_NEW='Kind taxonomy (choose CONSERVATIVELY — when torn between fact and anything else, NEVER pick fact): '"$SENTINEL"'
  - fact: ONLY third-party-verifiable, settled, non-contested (e.g. "X raised $5M in Mar 2024", "X is CEO of Y"). A contested statistic, a self-report, or any "most/best/leading/undervalued" claim is NOT a fact.
  - take: a stated opinion or evaluative judgement that could be wrong (e.g. "X is undervalued", "95% of AI pilots fail").
  - bet:  a forward-looking prediction — anything "will", "guide to", "expected to", or dated in the future (e.g. "X will IPO in 2026", "will reach $30B by 2027").
  - hunch: a low-confidence gut feeling or intuition (e.g. "Y feels overstretched").

Weight rules (round to the 0.05 grid; NO false precision like 0.74):
  - fact: 0.8 MAX unless directly quoted from a primary source (then up to 0.9).
  - self-reported facts ("X reports/says its revenue is Y"): cap 0.55 — below world-facts.
  - take (opinion): 0.5-0.7.  bet (prediction): 0.4-0.6.  hunch: 0.3-0.5.
  - Reserve 0.95-1.0 for consensus world-facts only.'
edit_once "$CMD" "$KIND_OLD" "$KIND_NEW" "kind+weight"

# Edit 2 — expanded named-trivia exclusion (signal_density).
SKIP_OLD='Skip pure narrative, questions, definitions, or pure quotes from others.'
SKIP_NEW='Skip (do NOT emit a take for): pure narrative, questions, definitions, pure quotes from others, AND all low-signal metadata — social handles, follower/subscriber counts, GitHub repo/star/fork counts, full team rosters or member lists, restated bio/title/headquarters/founded-year fields, URLs, and generic praise. Emit a take ONLY if it is load-bearing for a future query about what someone BELIEVES, PREDICTS, or what is contested.'
edit_once "$CMD" "$SKIP_OLD" "$SKIP_NEW" "signal-density-trivia"

# POST-AUDIT
if ! grep -qF "$SENTINEL" "$CMD"; then
  echo "[gbrain-patch:tqc-1] ERROR: post-apply audit — sentinel absent. FAILING THE BUILD." >&2; exit 1
fi
if ! grep -qF "choose CONSERVATIVELY" "$CMD" || ! grep -qF "Weight rules (round to the 0.05 grid" "$CMD" || ! grep -qF "low-signal metadata" "$CMD"; then
  echo "[gbrain-patch:tqc-1] ERROR: post-apply audit — one of the 3 improvements missing. FAILING THE BUILD." >&2; exit 1
fi
echo "[gbrain-patch:tqc-1] ✓ applied: CLASSIFIER_SYSTEM now has kind-conservatism + 0.05-grid weight caps + named-trivia exclusion."
echo "[gbrain-patch:tqc-1] done."
