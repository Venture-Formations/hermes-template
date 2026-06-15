#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-atom-drain-progress-guard.probe.sh   (still_needed_probe for FIX-AD-1)
#
# Answers, per upgrade, "did gbrain fix the extract_atoms drain no-progress
# break upstream, so this patch can be retired?" Run against the VANILLA
# (un-patched) candidate tree.
#
# The issue: the drain's per-batch break is gated on
#   `r.extracted === 0 && r.skipped === 0`
# but session_corpus_dir keeps re-discovering transcript duplicates so r.skipped
# is ~always > 0 → the guard never fires → 0-atom pages spin the whole window.
# OBSOLETE the day gbrain bases that break on real forward progress (no longer
# requires skipped===0 / compares remaining counts).
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
  echo "[ad-1-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

FILE="$GBRAIN_SRC/core/cycle/extract-atoms-drain.ts"
if [ ! -f "$FILE" ]; then
  echo "[ad-1-probe] UNKNOWN: extract-atoms-drain.ts not found — drain restructured; manual review." >&2
  exit 2
fi

# The broken guard, verbatim. If it's still here, the bug still exists.
if grep -qF "if (r.extracted === 0 && r.skipped === 0) { stopped = 'no_progress'; break; }" "$FILE"; then
  echo "[ad-1-probe] STILL NEEDED: drain break is still gated on skipped===0 — re-discovered duplicates (skipped>0) keep it from ever firing → 0-atom pages spin the window."
  exit 0
fi

# If the skipped===0 gate is gone but the loop still has a no_progress break and
# a remaining read, upstream likely re-based it on real progress → obsolete.
if grep -qF "stopped = 'no_progress'" "$FILE" && grep -qF 'countRemaining' "$FILE"; then
  echo "[ad-1-probe] OBSOLETE: the skipped===0 gate is gone and a no_progress break + remaining read remain — gbrain likely re-based the break on forward progress; review and retire FIX-AD-1."
  exit 1
fi

echo "[ad-1-probe] UNKNOWN: neither the broken gate nor the expected new shape present — drain break changed shape; manual review." >&2
exit 2
