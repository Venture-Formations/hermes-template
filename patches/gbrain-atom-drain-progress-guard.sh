#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-atom-drain-progress-guard.sh   (VF FIX-AD-1)
#
# WHY THIS EXISTS
# `runExtractAtomsDrain` (src/core/cycle/extract-atoms-drain.ts) is the bounded
# single-hold drain behind `gbrain dream --phase extract_atoms --drain`, the
# `extract-atoms-drain` Minion handler, and the autopilot auto-drain. Its
# per-batch "no forward progress" break is:
#     if (r.extracted === 0 && r.skipped === 0) { stopped = 'no_progress'; break; }
# That guard NEVER fires on this brain because session_corpus_dir
# (/data/brain/sources) keeps re-discovering transcript duplicates, so every
# batch returns duplicates_skipped > 0 (r.skipped > 0). A no-transcript page that
# clears the 500-char floor but yields 0 atoms therefore spins ~20 empty Haiku
# batches per run until the wallclock window times out — burning LLM budget and
# producing nothing. There are 13 such no-transcript pages on this brain
# (e.g. the 754-char sources/youtube/mm3ybi-9ccw). Atoms are otherwise healthy
# (~2516, produced by the gbrain-atom-drain cron); this is pure waste, not a
# correctness bug in atom output.
#
# WHAT THIS PATCH DOES
# Re-bases the break on REAL forward progress instead of "extracted==0 &&
# skipped==0". The loop already reads `const before = await deps.countRemaining()`
# at the top of each iteration (the remaining eligible-but-unextracted count
# BEFORE the batch). We add an after-batch `countRemaining()` and break when the
# batch extracted 0 NEW atoms AND the remaining count did not DROP versus `before`
# (no progress) — which is exactly the spin condition (0 atoms, backlog unchanged)
# regardless of how many duplicates were skipped. Progress-making batches still
# continue: any batch with `extracted > 0`, or one where `remaining` dropped, or
# where either count is null (query error — fail open, don't break early), keeps
# the loop going. The window / maxBatches caps are untouched; the `stopped` value
# stays 'no_progress' so callers and logs are unchanged.
#
# ANCHOR: the exact single break line above, present EXACTLY ONCE.
#
# This is a gbrain *core* modification. Applied at Docker BUILD time after the
# gbrain bake; baked into the image; re-applied on every GBRAIN_REF bump;
# idempotent (no-op if the FIX-AD-1 sentinel is already present); FAILS THE BUILD
# LOUDLY (old container keeps serving — no outage) if the anchor moved/changed,
# forcing a re-point — never a silent no-op. See UPGRADING_GBRAIN.md.
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
  echo "[gbrain-patch:ad-1] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

FILE="$GBRAIN_SRC/core/cycle/extract-atoms-drain.ts"
if [ ! -f "$FILE" ]; then
  echo "[gbrain-patch:ad-1] ERROR: $FILE not found — gbrain moved the drain module. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi
echo "[gbrain-patch:ad-1] target: $FILE"

ANCHOR="if (r.extracted === 0 && r.skipped === 0) { stopped = 'no_progress'; break; }"

# Idempotent: already applied?
if grep -qF 'FIX-AD-1' "$FILE"; then
  echo "[gbrain-patch:ad-1] ✓ already applied (FIX-AD-1 sentinel present); no-op."
  exit 0
fi

# PREFLIGHT — the anchor must be present EXACTLY ONCE.
n=$(grep -cF "$ANCHOR" "$FILE" || true)
if [ "$n" -eq 0 ]; then
  echo "[gbrain-patch:ad-1] ERROR: no-progress break anchor not found in $FILE:" >&2
  echo "[gbrain-patch:ad-1]   anchor: $ANCHOR" >&2
  echo "[gbrain-patch:ad-1] gbrain changed the drain break. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD (old container keeps serving)." >&2
  exit 1
elif [ "$n" -gt 1 ]; then
  echo "[gbrain-patch:ad-1] ERROR: drain break anchor is AMBIGUOUS ($n matches) in $FILE — a precise splice needs exactly one site. RE-POINT. FAILING THE BUILD." >&2
  exit 1
fi

# Also confirm the `before = countRemaining()` precondition the new logic reuses
# is still the per-iteration remaining read; if gbrain renamed/removed it the
# splice would reference an undefined var, so fail the build instead.
if ! grep -qF 'const before = await deps.countRemaining();' "$FILE"; then
  echo "[gbrain-patch:ad-1] ERROR: per-iteration 'const before = await deps.countRemaining();' read is gone — the drain loop shape changed. RE-POINT. FAILING THE BUILD." >&2
  exit 1
fi

REPLACEMENT="$(cat <<'EOF'
// FIX-AD-1 (hermes-template build patch): break on NO FORWARD PROGRESS, not on
      // extracted==0 && skipped==0. session_corpus_dir re-discovers transcript
      // duplicates so r.skipped is ~always > 0, meaning the original guard never
      // fired and a 0-atom no-transcript page spun the window full of empty Haiku
      // batches. Re-check remaining after the batch; a batch that extracted no NEW
      // atoms AND did not shrink the backlog (after >= before) is pure spin — stop.
      // Fail open: if either count is null (query error) keep going (window cap
      // still bounds us); any extracted>0 or a dropping `remaining` keeps draining.
      if (r.extracted === 0) {
        const after = await deps.countRemaining();
        if (before !== null && after !== null && after >= before) { stopped = 'no_progress'; break; }
      }
EOF
)"

# APPLY — exact one-line anchor replacement (no regex metachars in the anchor;
# Python exact .replace with a count assertion, mirroring FIX-TK-3).
ANCHOR="$ANCHOR" REPLACEMENT="$REPLACEMENT" python3 - "$FILE" <<'PYEOF'
import os, sys
path = sys.argv[1]
anchor = os.environ['ANCHOR']
replacement = os.environ['REPLACEMENT']
s = open(path, encoding='utf-8').read()
if s.count(anchor) != 1:
    sys.stderr.write("[gbrain-patch:ad-1] ERROR(py): expected exactly 1 anchor, found %d. FAILING.\n" % s.count(anchor))
    sys.exit(1)
open(path, 'w', encoding='utf-8').write(s.replace(anchor, replacement))
PYEOF

# POST-AUDIT — sentinel present, old anchor gone.
if ! grep -qF 'FIX-AD-1' "$FILE"; then
  echo "[gbrain-patch:ad-1] ERROR: post-apply audit failed — FIX-AD-1 sentinel absent after edit. FAILING THE BUILD." >&2
  exit 1
fi
if grep -qF "$ANCHOR" "$FILE"; then
  echo "[gbrain-patch:ad-1] ERROR: post-apply audit failed — original no-progress break still present. FAILING THE BUILD." >&2
  exit 1
fi
echo "[gbrain-patch:ad-1] ✓ applied: drain break now fires on no forward progress (extracted==0 && remaining did not drop)."
echo "[gbrain-patch:ad-1] done."
