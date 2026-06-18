#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-cycle-abort-signal.probe.sh   (still_needed_probe for FIX-CYCLE-ABORT-1)
#
# Answers, per upgrade, "did gbrain thread the abort signal into the
# lock-refreshing cycle phases upstream, so this patch can be retired?" Run
# against the VANILLA (un-patched) candidate tree.
#
# OBSOLETE the day upstream gives extract_atoms AND synthesize_concepts the
# #1972 consolidate.ts treatment: a `signal?: AbortSignal` opt + a cooperative
# isAborted/aborted check inside the phase, so a per-job-timeout abort exits the
# loop on its own (no zombie holding the cycle lock).
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
  echo "[cycle-abort-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

ATOMS="$GBRAIN_SRC/core/cycle/extract-atoms.ts"
SYNTH="$GBRAIN_SRC/core/cycle/synthesize-concepts.ts"
if [ ! -f "$ATOMS" ] || [ ! -f "$SYNTH" ]; then
  echo "[cycle-abort-probe] UNKNOWN: phase files not found (paths moved?)." >&2
  exit 2
fi

# Our own marker means we are looking at an already-patched tree (not vanilla) —
# the harness should probe the vanilla candidate; treat as STILL NEEDED.
if grep -qF 'VF (footgun fix): cooperative-abort signal threaded' "$ATOMS"; then
  echo "[cycle-abort-probe] STILL NEEDED (VF sentinel present — tree already patched)."
  exit 0
fi

# Upstream-fixed signature: BOTH phases declare a `signal?: AbortSignal` opt AND
# perform a cooperative abort check (isAborted(...) or *.signal?.aborted / .aborted).
atoms_opt=0; atoms_chk=0; synth_opt=0; synth_chk=0
grep -qE 'signal\??:\s*AbortSignal' "$ATOMS" && atoms_opt=1
grep -qE 'isAborted\(|\.signal\?\.aborted|signal\.aborted' "$ATOMS" && atoms_chk=1
grep -qE 'signal\??:\s*AbortSignal' "$SYNTH" && synth_opt=1
grep -qE 'isAborted\(|\.signal\?\.aborted|signal\.aborted' "$SYNTH" && synth_chk=1

if [ "$atoms_opt" = 1 ] && [ "$atoms_chk" = 1 ] && [ "$synth_opt" = 1 ] && [ "$synth_chk" = 1 ]; then
  echo "[cycle-abort-probe] OBSOLETE: vanilla extract_atoms + synthesize_concepts already thread + honor an AbortSignal — retire FIX-CYCLE-ABORT-1."
  exit 1
fi

echo "[cycle-abort-probe] STILL NEEDED: vanilla phases do not yet thread/honor the abort signal (atoms opt=$atoms_opt chk=$atoms_chk; synth opt=$synth_opt chk=$synth_chk)."
exit 0
