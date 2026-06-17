#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-voice-gate-judge-prefix.sh   (VF FIX-VG-1)
#
# WHY. core/calibration/voice-gate.ts defaultJudge() calls the calibration
# voice gate's Haiku judge with a PREFIX-LESS model id ('claude-haiku-4-5').
# parseModelId() in core/ai/model-resolver.ts THROWS on a prefix-less id
# (missing provider prefix), and it throws BEFORE the FIX-NA-1 reroute (which
# is injected after the parseModelId anchor). So FIX-NA-1 never reaches this
# call: the judge throws, the throw escapes gateVoice() (the judge call is not
# in the generator try/catch), and CalibrationProfilePhase fails-soft to an
# error — the calibration voice gate is silently dark every cycle.
#
# This deployment provisions no ANTHROPIC_API_KEY. Prefixing the id to
# 'anthropic:claude-haiku-4-5' makes parseModelId succeed, after which FIX-NA-1
# reroutes anthropic -> openrouter:auto ($0 via the grok proxy). Identical
# remedy to FIX-CME-1 for the cross-modal default slots.
#
# Applied at Docker BUILD time after the gbrain install + after FIX-NA-1;
# re-applied on every GBRAIN_REF bump; idempotent; FAILS THE BUILD LOUDLY if
# the anchor moved (never a silent no-op). See UPGRADING_GBRAIN.md.
# ---------------------------------------------------------------------------
set -euo pipefail

SENTINEL='VF-FIX-VG-1'
ANCHOR="model: 'claude-haiku-4-5',"
REPLACEMENT="model: 'anthropic:claude-haiku-4-5', // [VF-FIX-VG-1] prefix so FIX-NA-1 reroutes anthropic->openrouter:auto (bare id throws in parseModelId before reroute)"

GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[vg-prefix] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
TARGET="$GBRAIN_SRC/core/calibration/voice-gate.ts"
echo "[vg-prefix] target: $TARGET"

if [ ! -f "$TARGET" ]; then
  echo "[vg-prefix] ERROR: $TARGET missing — gbrain moved the voice gate. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi

# Idempotent: already applied?
if grep -qF "$SENTINEL" "$TARGET"; then
  echo "[vg-prefix] ✓ already applied ($SENTINEL present) — no-op."
  exit 0
fi

# Already-correct upstream? (gbrain may prefix it themselves one day.)
if grep -qF "model: 'anthropic:claude-haiku-4-5'" "$TARGET"; then
  echo "[vg-prefix] ✓ upstream already prefixes the judge id — patch obsolete, no-op."
  exit 0
fi

# Preflight: the bare anchor MUST be present. A moved/renamed anchor is a LOUD
# build failure, never a silent skip.
if ! grep -qF "$ANCHOR" "$TARGET"; then
  echo "[vg-prefix] ERROR: anchor not found in $TARGET:" >&2
  echo "[vg-prefix]   anchor: $ANCHOR" >&2
  echo "[vg-prefix] gbrain moved/renamed the voice-gate judge model literal. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD (old container keeps serving)." >&2
  exit 1
fi

# Replace exactly the one bare-id line. Use a Python in-place edit to avoid sed
# escaping pain with the quotes/colon.
python3 - "$TARGET" "$ANCHOR" "$REPLACEMENT" <<'PY'
import sys, io
path, anchor, repl = sys.argv[1], sys.argv[2], sys.argv[3]
with io.open(path, 'r', encoding='utf-8') as f:
    src = f.read()
n = src.count(anchor)
if n != 1:
    sys.stderr.write(f"[vg-prefix] ERROR: expected exactly 1 anchor, found {n}. FAILING THE BUILD.\n")
    sys.exit(1)
src = src.replace(anchor, repl, 1)
with io.open(path, 'w', encoding='utf-8') as f:
    f.write(src)
PY

# Post-audit: sentinel + new prefixed literal must both be present.
if ! grep -qF "$SENTINEL" "$TARGET"; then
  echo "[vg-prefix] ERROR: post-apply audit failed — $SENTINEL absent. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF "model: 'anthropic:claude-haiku-4-5'" "$TARGET"; then
  echo "[vg-prefix] ERROR: post-apply audit failed — prefixed literal missing. FAILING THE BUILD." >&2
  exit 1
fi
echo "[vg-prefix] ✓ applied: voice-gate judge id prefixed anthropic: (FIX-NA-1 now reroutes it to openrouter:auto)."
echo "[vg-prefix] done."
