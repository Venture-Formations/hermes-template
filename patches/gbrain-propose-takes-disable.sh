#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-propose-takes-disable.sh   (VF FIX-PT-2)
#
# WHY THIS EXISTS
# gbrain's dream/autopilot cycle runs the `propose_takes` calibration phase on
# EVERY tick. It is upstream-broken in two compounding ways, with NO enable gate
# to turn it off:
#
#   1. No consumer. propose_takes mines markdown prose for gradeable claims and
#      writes proposed takes, but there is NO review/accept CLI to ever consume
#      them (garrytan/gbrain GH #1467). The output accumulates unreviewed.
#   2. No negative-result cache. Every zero-take page is re-sent to the LLM on
#      every cycle — it never remembers "this page yielded nothing" (GH #2106) —
#      so a steady-state brain re-LLMs its entire corpus each tick (~$100/wk of
#      OpenRouter spend for output a reader never sees).
#
# Every OTHER optional cycle phase has an enable gate: `cycle.skillopt.enabled`
# (skillopt/cycle-phase.ts) and `cycle.conversation_facts_backfill.enabled`
# (both DEFAULT-OFF, read via engine.getConfig). propose_takes uniquely does NOT
# — it runs unconditionally whenever the phase is in the active list. There is no
# operator knob to stop the bleed short of patching the phase list itself.
#
# WHAT THIS PATCH DOES
# Adds the MISSING `cycle.propose_takes.enabled` gate to the propose_takes RUN
# block in src/core/cycle.ts, mirroring the skillopt/backfill convention exactly,
# DEFAULT-OFF: an absent config key ⇒ the phase is SKIPPED (status:'skipped',
# reason:'disabled') and never reaches the LLM. This INVERTS gbrain's upstream
# default (run-always) BY DESIGN — that is the entire point: the bleed must stay
# stopped across a rebuild AND a DB reset (absent key = OFF), and a missing key is
# the steady state, so OFF must be the no-config behaviour. Fully reversible at
# runtime with: gbrain config set cycle.propose_takes.enabled true
#
# The gate is injected as a BRACE-AWARE else-wrap of the existing run block
# (anchor line + body), so the original phase body is preserved verbatim inside
# the `else` and runs unchanged once the operator opts in. The surrounding
# `if (engine)` (engine guaranteed non-null here) and the sibling grade_takes /
# calibration_profile blocks are untouched.
#
# Applied at Docker BUILD time after the gbrain install; re-applied on every
# GBRAIN_REF bump; idempotent (no-op if VF-FIX-PT-2 already present); safe to
# re-run on a live container. FAILS THE BUILD LOUDLY (old container keeps serving
# — no outage) if its anchor moved or the calibration block was restructured, so
# the anchor gets re-pointed (never a silent no-op). See UPGRADING_GBRAIN.md.
# ---------------------------------------------------------------------------
set -euo pipefail

SENTINEL='VF-FIX-PT-2'
# The run-block opener — 8-space indent, trailing `) {`. UNIQUE (exactly once).
# The DECOY at the top of the calibration block ends in `||` and must NOT collide.
ANCHOR='        if (phases.includes('"'"'propose_takes'"'"')) {'
DECOY='if (phases.includes('"'"'propose_takes'"'"') ||'

# Resolve the gbrain source tree across build + runtime layouts.
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[pt-disable] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
TARGET="$GBRAIN_SRC/core/cycle.ts"
echo "[pt-disable] target: $TARGET"

if [ ! -f "$TARGET" ]; then
  echo "[pt-disable] ERROR: $TARGET missing — gbrain moved the cycle orchestrator. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi

# Idempotent: already applied?
if grep -qF "$SENTINEL" "$TARGET"; then
  echo "[pt-disable] ✓ already applied ($SENTINEL present) — no-op."
  exit 0
fi

# ---------------------------------------------------------------------------
# PREFLIGHT — self-audit BEFORE any edit. A moved/ambiguous anchor or a
# restructured calibration block is a LOUD build failure, never a silent skip.
# ---------------------------------------------------------------------------
PF_FAIL=0

# (1) The run-block anchor must be present EXACTLY ONCE. count==0 ⇒ gbrain moved
#     it; count>1 ⇒ ambiguous (a robust wrap must target one unique site).
ANCHOR_COUNT=$(grep -cF "$ANCHOR" "$TARGET" || true)
if [ "$ANCHOR_COUNT" -eq 0 ]; then
  echo "[pt-disable] ERROR: anchor not found in $TARGET:" >&2
  echo "[pt-disable]   anchor: $ANCHOR" >&2
  echo "[pt-disable] gbrain moved/renamed the propose_takes run block. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD (old container keeps serving)." >&2
  PF_FAIL=1
elif [ "$ANCHOR_COUNT" -gt 1 ]; then
  echo "[pt-disable] ERROR: anchor is AMBIGUOUS ($ANCHOR_COUNT matches) in $TARGET — a robust else-wrap needs exactly one site. The calibration block was restructured. RE-POINT. FAILING THE BUILD." >&2
  PF_FAIL=1
fi

# (2) The decoy guard line (the calibration-block opener that ends in `||`) must
#     still be present — its absence means the calibration block was restructured
#     and the run-block nesting / engine-guard assumptions no longer hold.
if ! grep -qF "$DECOY" "$TARGET"; then
  echo "[pt-disable] ERROR: decoy guard line ('if (phases.includes('\''propose_takes'\'') ||') gone from $TARGET — the calibration block was restructured. RE-POINT. FAILING THE BUILD." >&2
  PF_FAIL=1
fi

# (3) The run block must still dynamic-import runPhaseProposeTakes (the body we
#     wrap) and live inside the calibrationCtx construction — both prove we're
#     wrapping the right block.
if ! grep -qF 'runPhaseProposeTakes' "$TARGET"; then
  echo "[pt-disable] ERROR: 'runPhaseProposeTakes' gone from $TARGET — propose_takes phase restructured. RE-POINT. FAILING THE BUILD." >&2
  PF_FAIL=1
fi
if ! grep -qF 'calibrationCtx' "$TARGET"; then
  echo "[pt-disable] ERROR: 'calibrationCtx' gone from $TARGET — calibration block restructured; engine non-null guarantee no longer provable. RE-POINT. FAILING THE BUILD." >&2
  PF_FAIL=1
fi

if [ "$PF_FAIL" = "1" ]; then
  echo "[pt-disable] ERROR: preflight failed — see errors above. Nothing patched." >&2
  exit 1
fi
echo "[pt-disable] preflight: anchor unique, decoy present, runPhaseProposeTakes + calibrationCtx present."

# ---------------------------------------------------------------------------
# INJECT — robust BRACE-AWARE else-wrap of the propose_takes run block.
#
# Python locates the unique anchor line, brace-counts from its trailing `{` to
# the matching close-brace (so it survives reformatting of the body — never a
# fragile "insert a lone } before grade_takes" hack), then rewrites the block as:
#
#   if (phases.includes('propose_takes')) {
#     // [VF-FIX-PT-2] default-OFF gate (read at top of block)
#     <gate read>
#     if (!enabled) { push skipped; safeYield; }
#     else { <ORIGINAL BODY, re-indented> }
#   }
#
# The gate read uses engine.getConfig (engine is non-null inside `if (engine)`),
# mirroring cycle.skillopt.enabled / cycle.conversation_facts_backfill.enabled.
# ---------------------------------------------------------------------------
python3 - "$TARGET" <<'PYEOF'
import sys

path = sys.argv[1]
src = open(path, 'r', encoding='utf-8').read()
lines = src.split('\n')

ANCHOR = "        if (phases.includes('propose_takes')) {"

# Locate the unique anchor line (preflight already asserted count==1).
idxs = [i for i, ln in enumerate(lines) if ln == ANCHOR]
if len(idxs) != 1:
    sys.stderr.write(
        "[pt-disable] ERROR(py): expected exactly 1 anchor line, found %d. FAILING.\n" % len(idxs))
    sys.exit(1)
start = idxs[0]

# Brace-count from the first `{` on the anchor line to its matching close.
# Track only braces (the body is well-formed TS; no brace-in-string edge case
# occurs in this block — but we still scan char-by-char from the opener).
open_pos = lines[start].index('{')
depth = 0
end = None
end_col = None
found_first = False
for li in range(start, len(lines)):
    line = lines[li]
    col_from = open_pos if li == start else 0
    for ci in range(col_from, len(line)):
        ch = line[ci]
        if ch == '{':
            depth += 1
            found_first = True
        elif ch == '}':
            depth -= 1
            if found_first and depth == 0:
                end = li
                end_col = ci
                break
    if end is not None:
        break

if end is None:
    sys.stderr.write("[pt-disable] ERROR(py): could not find matching close-brace for the run block. FAILING.\n")
    sys.exit(1)

# The block opener line (anchor) and the close-brace line. The close-brace for
# this block is expected to be a lone `        }` line; assert that so we don't
# mangle a same-line construct.
close_line = lines[end]
if close_line.strip() != '}':
    sys.stderr.write(
        "[pt-disable] ERROR(py): run-block close-brace is not a lone '}' line (got %r) — body shape changed. RE-POINT. FAILING.\n" % close_line)
    sys.exit(1)

# Original body = the lines strictly between the anchor line and the close line.
body = lines[start + 1:end]

# Re-indent the original body by +2 spaces (it now lives inside the `else {`).
reindented = []
for ln in body:
    reindented.append(('  ' + ln) if ln.strip() else ln)

# Build the rewritten block. Base indent of the anchor body is 10 spaces.
B = '          '   # 10-space base (one level inside the 8-space anchor)
gate = []
gate.append(ANCHOR)
gate.append(B + "// [VF-FIX-PT-2] DEFAULT-OFF gate for the upstream-broken propose_takes phase.")
gate.append(B + "// propose_takes has no consumer/review CLI (GH #1467) and no negative-result")
gate.append(B + "// cache (GH #2106 — re-LLMs every zero-take page each cycle, ~$100/wk), and is")
gate.append(B + "// the ONLY optional cycle phase upstream ships with no enable gate. This adds")
gate.append(B + "// the missing `cycle.propose_takes.enabled` knob, mirroring cycle.skillopt.enabled")
gate.append(B + "// / cycle.conversation_facts_backfill.enabled. Absent key ⇒ SKIPPED (inverts the")
gate.append(B + "// upstream run-always default BY DESIGN; survives rebuild + DB reset). Re-enable:")
gate.append(B + "//   gbrain config set cycle.propose_takes.enabled true")
gate.append(B + "let _ptRaw: string | null = null;")
gate.append(B + "try { _ptRaw = await engine.getConfig('cycle.propose_takes.enabled'); } catch { _ptRaw = null; }")
gate.append(B + "const _ptEnabled = _ptRaw != null && !['false', '0', 'no', 'off', ''].includes(_ptRaw.trim().toLowerCase());")
gate.append(B + "if (!_ptEnabled) {")
gate.append(B + "  phaseResults.push({")
gate.append(B + "    phase: 'propose_takes',")
gate.append(B + "    status: 'skipped',")
gate.append(B + "    duration_ms: 0,")
gate.append(B + "    summary: 'cycle.propose_takes.enabled not true (VF-FIX-PT-2 default OFF)',")
gate.append(B + "    details: { reason: 'disabled', enable_hint: 'gbrain config set cycle.propose_takes.enabled true' },")
gate.append(B + "  });")
gate.append(B + "  await safeYield(opts.yieldBetweenPhases);")
gate.append(B + "} else {")
gate.extend(reindented)
gate.append(B + "}")
gate.append(close_line)  # the original lone `}` closing the run block

new_lines = lines[:start] + gate + lines[end + 1:]
out = '\n'.join(new_lines)
open(path, 'w', encoding='utf-8').write(out)
sys.stderr.write("[pt-disable] python: else-wrap injected (block lines %d..%d).\n" % (start + 1, end + 1))
PYEOF

# ---------------------------------------------------------------------------
# POST-AUDIT — the gate MUST now be present. Never report success on a no-op.
# ---------------------------------------------------------------------------
if ! grep -qF "$SENTINEL" "$TARGET"; then
  echo "[pt-disable] ERROR: post-apply audit failed — $SENTINEL absent after inject. Injection did not land. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF "engine.getConfig('cycle.propose_takes.enabled')" "$TARGET"; then
  echo "[pt-disable] ERROR: post-apply audit failed — getConfig('cycle.propose_takes.enabled') literal missing. FAILING THE BUILD." >&2
  exit 1
fi
# Defensive: the original body must survive (runPhaseProposeTakes still imported
# inside the wrapped else).
if ! grep -qF 'runPhaseProposeTakes' "$TARGET"; then
  echo "[pt-disable] ERROR: post-apply audit failed — runPhaseProposeTakes vanished; the wrap dropped the original body. FAILING THE BUILD." >&2
  exit 1
fi
echo "[pt-disable] ✓ applied: propose_takes now gated behind cycle.propose_takes.enabled (DEFAULT OFF)."
echo "[pt-disable] done."
