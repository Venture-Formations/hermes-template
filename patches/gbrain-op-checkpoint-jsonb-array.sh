#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-op-checkpoint-jsonb-array.sh   (VF FIX-OCK-1)
#
# WHY THIS EXISTS
# gbrain `recordCompleted` (src/core/op-checkpoint.ts) persists a checkpoint's
# completed_keys via:
#     INSERT INTO op_checkpoints (op, fingerprint, completed_keys, updated_at)
#     VALUES ($1, $2, $3::jsonb, now()) ...      with [op, fp, JSON.stringify(sorted)]
# On the POSTGRES engine (this deployment = Supabase Postgres, postgres.js
# `.unsafe()` binding) the JSON.stringify'd array text bound to a `$3::jsonb`
# cast is DOUBLE-ENCODED into a jsonb STRING SCALAR (`jsonb_typeof = 'string'`),
# which violates migration v119's CHECK constraint
# `op_checkpoints_completed_keys_array` (`jsonb_typeof(completed_keys) = 'array'`,
# shipped in gbrain v0.42.51.0). recordCompleted is non-fatal for most ops
# (logged, re-walk next run) but FATAL for SYNC: the `sync-target` pin write
# aborts EVERY incremental sync ("imported 0 of N", reason=checkpoint_unavailable)
# — so brain search silently goes stale. It also silently corrupts
# extract-conversation-facts / enrich / extract --by-mention checkpoints.
#
# Reproduced empirically on the live Supabase DB (postgres.js 3.4.9): the current
# binding stores a string scalar; `to_jsonb($3::text[])` with the raw array bound
# stores a proper jsonb array. This is the UPSTREAM-CONVERGENT fix (PRs
# #2355/#2333/#2328/#2309 et al.) and mirrors the in-file `appendCompleted`
# precedent one function below, which already binds `unnest($3::text[])`.
# gbrain's own PGLite test default HIDES the bug, so it ships unfixed on master.
#
# TIME-BOXED BRIDGE: this is written IDENTICAL to the upstream fix so it
# self-obsoletes the day master lands any of the convergent PRs — the
# still_needed_probe flips to OBSOLETE on the next GBRAIN_REF bump. Applied at
# Docker BUILD time after the gbrain install; re-applied on every bump;
# idempotent; FAILS THE BUILD LOUDLY (old container keeps serving — no outage)
# if its anchor moved, never a silent no-op. See
# patches/gbrain-op-checkpoint-jsonb-array.meta.yml + UPGRADING_GBRAIN.md.
# ---------------------------------------------------------------------------
set -euo pipefail

SENTINEL='VF-FIX-OCK-1'

# Resolve the gbrain source tree across build + runtime layouts.
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[ock-1] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
TARGET="$GBRAIN_SRC/core/op-checkpoint.ts"
echo "[ock-1] target: $TARGET"

if [ ! -f "$TARGET" ]; then
  echo "[ock-1] ERROR: $TARGET missing — gbrain moved op-checkpoint. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi

# Idempotent: already applied?
if grep -qF "$SENTINEL" "$TARGET"; then
  echo "[ock-1] ✓ already applied ($SENTINEL present) — no-op."
  exit 0
fi

# Preflight: both anchors MUST be present (the recordCompleted INSERT + its param
# array). A moved/renamed anchor is a LOUD build failure, never a silent skip.
# These two strings are unique to recordCompleted — appendCompleted (the safe
# precedent below it) uses `'[]'::jsonb` + `unnest($3::text[])`, a different shape.
ANCHOR='VALUES ($1, $2, $3::jsonb, now())'
ANCHOR_PARAMS='[key.op, key.fingerprint, JSON.stringify(sorted)],'
if ! grep -qF "$ANCHOR" "$TARGET" || ! grep -qF "$ANCHOR_PARAMS" "$TARGET"; then
  echo "[ock-1] ERROR: anchor(s) not found in $TARGET — gbrain rewrote recordCompleted (it may have fixed this upstream)." >&2
  echo "[ock-1]   anchor 1: $ANCHOR" >&2
  echo "[ock-1]   anchor 2: $ANCHOR_PARAMS" >&2
  echo "[ock-1] RE-POINT or RETIRE this patch (see still_needed_probe). FAILING THE BUILD (old container keeps serving)." >&2
  exit 1
fi

# Literal, exact replacement via node (robust vs sed bracket-expression hazards
# in `$3::text[]` / the param array). Bind the raw string[] and cast in SQL with
# to_jsonb($3::text[]) — postgres.js sends a JS array as a Postgres text[], which
# to_jsonb turns into a proper jsonb array (satisfying the v119 CHECK).
OCK_TARGET="$TARGET" node <<'NODE'
const fs = require('fs');
const f = process.env.OCK_TARGET;
let s = fs.readFileSync(f, 'utf8');
const A1 = 'VALUES ($1, $2, $3::jsonb, now())';
const R1 = 'VALUES ($1, $2, to_jsonb($3::text[]), now()) /* VF-FIX-OCK-1 */';
const A2 = '[key.op, key.fingerprint, JSON.stringify(sorted)],';
const R2 = '[key.op, key.fingerprint, sorted], // VF-FIX-OCK-1: bind string[] -> to_jsonb($3::text[]) (postgres.js double-encodes JSON.stringify into a jsonb scalar string, tripping the v119 array CHECK)';
if (s.indexOf(A1) < 0 || s.indexOf(A2) < 0) { console.error('[ock-1] anchor(s) vanished mid-apply'); process.exit(1); }
s = s.split(A1).join(R1).split(A2).join(R2);
fs.writeFileSync(f, s);
NODE

# Post-audit: the sentinel MUST be present and the broken form MUST be gone.
if ! grep -qF "$SENTINEL" "$TARGET"; then
  echo "[ock-1] ERROR: post-apply audit failed — $SENTINEL absent after edit. FAILING THE BUILD." >&2
  exit 1
fi
if grep -qF "$ANCHOR" "$TARGET"; then
  echo "[ock-1] ERROR: post-apply audit failed — broken \$3::jsonb form still present. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF 'to_jsonb($3::text[])' "$TARGET"; then
  echo "[ock-1] ERROR: post-apply audit failed — to_jsonb(\$3::text[]) not present. FAILING THE BUILD." >&2
  exit 1
fi
echo "[ock-1] ✓ applied: recordCompleted now binds string[] -> to_jsonb(\$3::text[]) (satisfies the v119 op_checkpoints array CHECK; unblocks sync-target)."
echo "[ock-1] done."
