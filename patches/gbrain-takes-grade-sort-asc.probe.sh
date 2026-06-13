#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-takes-grade-sort-asc.probe.sh   (still_needed_probe for FIX-TK-3)
#
# Answers, per upgrade, "did gbrain fix the grade_takes since_date sort upstream,
# so this patch can be retired?" Run against the VANILLA (un-patched) candidate
# tree.
#
# The issue: grade_takes wants oldest-first but the engines ORDER BY since_date
# DESC, so the 50-take window only ever holds the newest (too-recent) takes →
# 0 verdicts. OBSOLETE the day gbrain ships the since_date sort as ASC (or
# otherwise loads grade_takes oldest-first).
#
# Exit codes (harness contract):
#   0 = STILL NEEDED   1 = OBSOLETE   2 = UNKNOWN
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
  echo "[tk3-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

PG="$GBRAIN_SRC/core/postgres-engine.ts"
GT="$GBRAIN_SRC/core/cycle/grade-takes.ts"
if [ ! -f "$PG" ]; then
  echo "[tk3-probe] UNKNOWN: postgres-engine.ts not found — tree restructured; manual review." >&2
  exit 2
fi

# Confirm grade_takes still sorts by since_date with a bounded window (the failure
# precondition). If that whole shape is gone, the patch's premise changed.
if [ -f "$GT" ] && ! grep -qF "sortBy: 'since_date'" "$GT"; then
  echo "[tk3-probe] UNKNOWN: grade-takes no longer sorts by since_date — phase restructured; manual review." >&2
  exit 2
fi

if grep -qF 'THEN t.since_date END ASC NULLS LAST' "$PG"; then
  echo "[tk3-probe] OBSOLETE: gbrain now orders the since_date sort ASC (oldest-first) natively — review and retire FIX-TK-3."
  exit 1
fi
if grep -qF 'THEN t.since_date END DESC NULLS LAST' "$PG"; then
  echo "[tk3-probe] STILL NEEDED: since_date sort is still DESC (newest-first) — grade_takes' 50-window never reaches old gradeable takes."
  exit 0
fi

echo "[tk3-probe] UNKNOWN: neither the DESC anchor nor the ASC result present — since_date ORDER BY changed shape; manual review." >&2
exit 2
