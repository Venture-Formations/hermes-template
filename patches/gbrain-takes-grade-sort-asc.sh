#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-takes-grade-sort-asc.sh   (VF FIX-TK-3)
#
# WHY THIS EXISTS
# The dream/autopilot `grade_takes` phase loads unresolved takes to grade with:
#     engine.listTakes({ resolved:false, active:true, sortBy:'since_date', limit })
# and its own comment says "Load unresolved active takes, oldest-first." But BOTH
# engines order the since_date sort NEWEST-first:
#     CASE WHEN ... = 'since_date' THEN t.since_date END DESC NULLS LAST
# (src/core/postgres-engine.ts + src/core/pglite-engine.ts). With the default
# 50-take limit, grade_takes therefore only ever loads the 50 NEWEST-dated takes —
# which on a steady-state brain are all younger than the min-age gate (default 6mo)
# — so `takeIsOldEnough` rejects all 50 and grade_takes writes ZERO verdicts every
# cycle, no matter how many genuinely-old gradeable takes exist further down. That
# starves take_grade_cache, calibration_profiles, dream_verdicts, and the eval
# surface (all 0 rows). `grade_takes` (cycle/grade-takes.ts:420) is the ONLY caller
# of sortBy:'since_date' in the tree, so flipping that one ORDER BY to ASC is safe
# and exactly realises the "oldest-first" the code already documents.
#
# WHAT THIS PATCH DOES
# Flips the since_date ORDER BY from `DESC NULLS LAST` to `ASC NULLS LAST` on the
# single since_date sort line in BOTH engines (parity), so grade_takes loads the
# OLDEST dated takes first and actually reaches the age-eligible ones. NULLS LAST
# is preserved, so date-less takes still sort to the end (grade_takes filters them
# out anyway). No other behaviour changes; no other sortBy:'since_date' caller
# exists.
#
# Applied at Docker BUILD time after the gbrain install; re-applied on every
# GBRAIN_REF bump; idempotent (no-op if already ASC); FAILS THE BUILD LOUDLY (old
# container keeps serving — no outage) if the sort line moved/changed, so the
# anchor gets re-pointed (never a silent no-op). See UPGRADING_GBRAIN.md.
# ---------------------------------------------------------------------------
set -euo pipefail

DESC_ANCHOR='THEN t.since_date END DESC NULLS LAST'
ASC_RESULT='THEN t.since_date END ASC NULLS LAST'

# Resolve the gbrain source tree across build + runtime layouts.
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[tk3-sort] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

# Both engines carry the identical since_date sort line. postgres-engine.ts is the
# live engine on this deployment; pglite-engine.ts is patched for parity (gbrain
# keeps the two in lockstep). Both are REQUIRED — a drift in either fails the build.
TARGETS="$GBRAIN_SRC/core/postgres-engine.ts $GBRAIN_SRC/core/pglite-engine.ts"

patch_one() {
  local target="$1"
  echo "[tk3-sort] target: $target"
  if [ ! -f "$target" ]; then
    echo "[tk3-sort] ERROR: $target missing — gbrain moved the engine. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
    return 1
  fi

  # Idempotent: already ASC?
  if grep -qF "$ASC_RESULT" "$target"; then
    if grep -qF "$DESC_ANCHOR" "$target"; then
      echo "[tk3-sort] ERROR: $target has BOTH the ASC result AND the DESC anchor — ambiguous/duplicated sort line. RE-POINT. FAILING THE BUILD." >&2
      return 1
    fi
    echo "[tk3-sort] ✓ already applied (ASC present) in $(basename "$target") — no-op."
    return 0
  fi

  # PREFLIGHT — the DESC anchor must be present EXACTLY ONCE.
  local n
  n=$(grep -cF "$DESC_ANCHOR" "$target" || true)
  if [ "$n" -eq 0 ]; then
    echo "[tk3-sort] ERROR: since_date sort anchor not found in $target:" >&2
    echo "[tk3-sort]   anchor: $DESC_ANCHOR" >&2
    echo "[tk3-sort] gbrain changed the since_date ORDER BY. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD (old container keeps serving)." >&2
    return 1
  elif [ "$n" -gt 1 ]; then
    echo "[tk3-sort] ERROR: since_date sort anchor is AMBIGUOUS ($n matches) in $target — a precise flip needs exactly one site. RE-POINT. FAILING THE BUILD." >&2
    return 1
  fi

  # APPLY — exact-substring flip (no regex metachars in the anchor).
  python3 - "$target" "$DESC_ANCHOR" "$ASC_RESULT" <<'PYEOF'
import sys
path, anchor, result = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
if s.count(anchor) != 1:
    sys.stderr.write("[tk3-sort] ERROR(py): expected exactly 1 anchor, found %d. FAILING.\n" % s.count(anchor))
    sys.exit(1)
open(path, 'w', encoding='utf-8').write(s.replace(anchor, result))
PYEOF

  # POST-AUDIT — ASC must now be present and DESC gone.
  if ! grep -qF "$ASC_RESULT" "$target"; then
    echo "[tk3-sort] ERROR: post-apply audit failed — ASC result absent in $target after edit. FAILING THE BUILD." >&2
    return 1
  fi
  if grep -qF "$DESC_ANCHOR" "$target"; then
    echo "[tk3-sort] ERROR: post-apply audit failed — DESC anchor still present in $target. FAILING THE BUILD." >&2
    return 1
  fi
  echo "[tk3-sort] ✓ applied: since_date sort flipped DESC→ASC (oldest-first) in $(basename "$target")."
  return 0
}

rc=0
for t in $TARGETS; do
  patch_one "$t" || rc=1
done
if [ "$rc" != "0" ]; then
  echo "[tk3-sort] ERROR: one or more engines failed to patch — see above. FAILING THE BUILD." >&2
  exit 1
fi
echo "[tk3-sort] done."
