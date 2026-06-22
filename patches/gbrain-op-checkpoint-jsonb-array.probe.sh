#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-op-checkpoint-jsonb-array.probe.sh   (still_needed_probe for FIX-OCK-1)
#
# Answers, per upgrade, "did this gbrain version fix the recordCompleted
# jsonb-array bug upstream, so the patch can be retired?" Run by the WS4 dry-run
# against the VANILLA (un-patched) candidate tree, and by verify-upgrade.sh.
#
# The bug: recordCompleted binds JSON.stringify(sorted) to a $3::jsonb cast,
# which postgres.js double-encodes into a jsonb scalar string -> violates the
# v119 op_checkpoints_completed_keys_array CHECK -> sync-target write aborts.
# OBSOLETE the day upstream binds the array properly (to_jsonb($3::text[]) /
# raw text[] / sql.json) so the broken `JSON.stringify(sorted)` + `$3::jsonb`
# pair is gone from recordCompleted.
#
# Exit codes (harness contract):
#   0 = STILL NEEDED  — broken form reproduces on this ref; keep the patch
#   1 = OBSOLETE      — upstream fixed it; recommend retirement
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
  echo "[ock-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

TARGET="$GBRAIN_SRC/core/op-checkpoint.ts"
if [ ! -f "$TARGET" ]; then
  echo "[ock-probe] UNKNOWN: $TARGET not found (recordCompleted moved?)." >&2
  exit 2
fi

# Already patched (e.g. probing a patched tree)? Then it's still needed by definition.
if grep -qF 'VF-FIX-OCK-1' "$TARGET"; then
  echo "[ock-probe] STILL NEEDED: VF-FIX-OCK-1 present (patched tree)."
  exit 0
fi

# The broken pair: the $3::jsonb INSERT AND the JSON.stringify(sorted) param.
HAS_CAST=0; grep -qF 'VALUES ($1, $2, $3::jsonb, now())' "$TARGET" && HAS_CAST=1
HAS_STRINGIFY=0; grep -qF '[key.op, key.fingerprint, JSON.stringify(sorted)],' "$TARGET" && HAS_STRINGIFY=1

echo "[ock-probe] broken \$3::jsonb INSERT: $HAS_CAST ; JSON.stringify(sorted) param: $HAS_STRINGIFY"

if [ "$HAS_CAST" -eq 1 ] && [ "$HAS_STRINGIFY" -eq 1 ]; then
  echo "[ock-probe] STILL NEEDED: recordCompleted still double-encodes (broken \$3::jsonb + JSON.stringify(sorted))."
  exit 0
fi
echo "[ock-probe] OBSOLETE: the broken recordCompleted binding is gone upstream — review and RETIRE FIX-OCK-1 (drop the patch triple + Dockerfile RUN + verify-upgrade block)."
exit 1
