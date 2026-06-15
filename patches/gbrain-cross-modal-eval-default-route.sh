#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-cross-modal-eval-default-route.sh   (VF FIX-CME-1)
#
# WHY THIS EXISTS
# `gbrain eval cross-modal` scores an OUTPUT with THREE different-provider
# frontier models (slots A/B/C). The default slot model ids live in
# `DEFAULT_SLOTS` (src/core/cross-modal-eval/runner.ts) and the command
# (src/commands/eval-cross-modal.ts) reads them via
# `parsed.slot{A,B,C}Model ?? DEFAULT_SLOTS[i].model`. Vanilla defaults are:
#     A: openai:gpt-4o
#     B: anthropic:claude-opus-4-7
#     C: google:gemini-1.5-pro
# Only slot B (`anthropic:`) is rerouted to grok ($0) by our FIX-NA-1
# chokepoint (model-resolver.ts). slot A bills the native OPENAI_API_KEY and
# slot C bills the native Google key. The command is NOT cron-wired
# (operator-only), so the leak only fires on a manual `gbrain eval cross-modal`
# run — but the no-native-billing invariant says the DEFAULT must be
# billing-safe. (Mirrors the eval-takes-quality / no-native-billing decision.)
#
# WHAT THIS PATCH DOES
# Re-points the THREE DEFAULT_SLOTS model ids to DISTINCT `anthropic:` ids so a
# default run is rerouted ENTIRELY to grok ($0 via FIX-NA-1):
#     A: openai:gpt-4o            -> anthropic:claude-opus-4-7
#     B: anthropic:claude-opus-4-7 -> anthropic:claude-sonnet-4-6
#     C: google:gemini-1.5-pro    -> anthropic:claude-haiku-4-5
# All three reroute to grok:grok-4.3 via FIX-NA-1 (a native `anthropic:` id
# with no ANTHROPIC_API_KEY -> live default -> grok). Distinct ids preserve the
# 3-slot structure. The explicit `--slot-a-model/--slot-b-model/--slot-c-model`
# overrides are LEFT UNCHANGED (the command still reads
# `parsed.slotXModel ?? DEFAULT_SLOTS[i].model`), so an operator can still
# deliberately opt into native multi-provider diversity (and native billing) by
# passing them. The 3 HELP one-liners in eval-cross-modal.ts that document the
# old defaults are updated to match (cosmetic, keeps --help honest). Nothing
# else in the command changes.
#
# ANCHORS:
#   runner.ts (load-bearing):
#     { id: 'A', model: 'openai:gpt-4o' },
#     { id: 'C', model: 'google:gemini-1.5-pro' },
#   eval-cross-modal.ts (HELP, cosmetic):
#     --slot-a-model <id>      Override default 'openai:gpt-4o'.
#     --slot-c-model <id>      Override default 'google:gemini-1.5-pro'.
#   Each present EXACTLY ONCE.
#
# This is a gbrain *core* modification. Applied at Docker BUILD time after the
# gbrain bake; baked into the image; re-applied on every GBRAIN_REF bump;
# idempotent (no-op if the FIX-CME-1 sentinel is already present); FAILS THE
# BUILD LOUDLY (old container keeps serving — no outage) if an anchor
# moved/changed, forcing a re-point — never a silent no-op. See
# UPGRADING_GBRAIN.md.
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
  echo "[gbrain-patch:cme-1] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

RUNNER="$GBRAIN_SRC/core/cross-modal-eval/runner.ts"
CMD="$GBRAIN_SRC/commands/eval-cross-modal.ts"
for f in "$RUNNER" "$CMD"; do
  if [ ! -f "$f" ]; then
    echo "[gbrain-patch:cme-1] ERROR: $f not found — gbrain moved the cross-modal eval module. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
    exit 1
  fi
done
echo "[gbrain-patch:cme-1] targets: $RUNNER ; $CMD"

# Sentinel: the rerouted slot-A default we splice into runner.ts. Re-run = no-op.
SENTINEL="// FIX-CME-1"

# Idempotent: already applied?
if grep -qF "$SENTINEL" "$RUNNER"; then
  echo "[gbrain-patch:cme-1] ✓ already applied (FIX-CME-1 sentinel present in runner.ts); no-op."
  exit 0
fi

# --- ANCHORS (must each be present EXACTLY ONCE) --------------------------
RA_OPENAI="{ id: 'A', model: 'openai:gpt-4o' },"
RC_GOOGLE="{ id: 'C', model: 'google:gemini-1.5-pro' },"
HA_OPENAI="  --slot-a-model <id>      Override default 'openai:gpt-4o'."
HC_GOOGLE="  --slot-c-model <id>      Override default 'google:gemini-1.5-pro'."

check_once() {
  local needle="$1" file="$2" label="$3"
  local n
  n=$(grep -cF "$needle" "$file" || true)
  if [ "$n" -eq 0 ]; then
    echo "[gbrain-patch:cme-1] ERROR: anchor [$label] not found in $file:" >&2
    echo "[gbrain-patch:cme-1]   anchor: $needle" >&2
    echo "[gbrain-patch:cme-1] gbrain changed the cross-modal defaults. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD (old container keeps serving)." >&2
    exit 1
  elif [ "$n" -gt 1 ]; then
    echo "[gbrain-patch:cme-1] ERROR: anchor [$label] is AMBIGUOUS ($n matches) in $file — a precise splice needs exactly one site. RE-POINT. FAILING THE BUILD." >&2
    exit 1
  fi
}
check_once "$RA_OPENAI" "$RUNNER" "runner.slotA-openai"
check_once "$RC_GOOGLE" "$RUNNER" "runner.slotC-google"
check_once "$HA_OPENAI" "$CMD" "help.slotA-openai"
check_once "$HC_GOOGLE" "$CMD" "help.slotC-google"

# Confirm slot B is still the anthropic:claude-opus-4-7 default we re-home to
# slot A — guards against an upstream slot reshuffle producing a duplicate id.
if ! grep -qF "{ id: 'B', model: 'anthropic:claude-opus-4-7' }," "$RUNNER"; then
  echo "[gbrain-patch:cme-1] ERROR: expected slot-B 'anthropic:claude-opus-4-7' default is gone from $RUNNER — slot layout changed. RE-POINT. FAILING THE BUILD." >&2
  exit 1
fi

# Replacements.
RA_NEW="{ id: 'A', model: 'anthropic:claude-opus-4-7' }, ${SENTINEL} (hermes-template build patch): re-route the 3 cross-modal eval default slots to DISTINCT anthropic ids so a default \`gbrain eval cross-modal\` run is rerouted entirely to grok (\$0) via the FIX-NA-1 chokepoint, instead of billing the native OPENAI_API_KEY (slot A) + Google key (slot C). Distinct ids keep the 3-slot structure (all reroute to grok:grok-4.3). The --slot-a/b/c-model overrides are unchanged, so an operator can still pass native ids for real multi-provider diversity + native billing. See gbrain-cross-modal-eval-default-route.meta.yml."
RB_NEW="{ id: 'B', model: 'anthropic:claude-sonnet-4-6' },"
RC_NEW="{ id: 'C', model: 'anthropic:claude-haiku-4-5' },"
HA_NEW="  --slot-a-model <id>      Override default 'anthropic:claude-opus-4-7' (FIX-CME-1; reroutes to grok)."
HC_NEW="  --slot-c-model <id>      Override default 'anthropic:claude-haiku-4-5' (FIX-CME-1; reroutes to grok)."

# Slot B HELP line documents the old slot-B default (claude-opus-4-7); slot B's
# default is now claude-sonnet-4-6, so keep --help honest. Cosmetic; no count
# guard up top (slot B was already anthropic / billing-safe) — edit only if the
# exact old HELP line is present, else skip (forward-compatible).
HB_OLD="  --slot-b-model <id>      Override default 'anthropic:claude-opus-4-7'."
HB_NEW="  --slot-b-model <id>      Override default 'anthropic:claude-sonnet-4-6' (FIX-CME-1; reroutes to grok)."

# Slot B old/new for the runner edit.
RB_OLD="{ id: 'B', model: 'anthropic:claude-opus-4-7' },"

# APPLY — exact one-line anchor replacements (no regex metachars; Python exact
# .replace with count assertions, mirroring FIX-AD-1 / FIX-TK-3).
edit_once() {
  local file="$1" old="$2" new="$3"
  OLD="$old" NEW="$new" python3 - "$file" <<'PYEOF'
import os, sys
path = sys.argv[1]
old = os.environ['OLD']
new = os.environ['NEW']
s = open(path, encoding='utf-8').read()
if s.count(old) != 1:
    sys.stderr.write("[gbrain-patch:cme-1] ERROR(py): expected exactly 1 occurrence of an anchor in %s, found %d. FAILING.\n" % (path, s.count(old)))
    sys.exit(1)
open(path, 'w', encoding='utf-8').write(s.replace(old, new))
PYEOF
}

# runner.ts: slot A, slot B, slot C
edit_once "$RUNNER" "$RA_OPENAI" "$RA_NEW"
edit_once "$RUNNER" "$RB_OLD"    "$RB_NEW"
edit_once "$RUNNER" "$RC_GOOGLE" "$RC_NEW"
# eval-cross-modal.ts: HELP lines for slot A + slot C.
edit_once "$CMD" "$HA_OPENAI" "$HA_NEW"
edit_once "$CMD" "$HC_GOOGLE" "$HC_NEW"
# slot B HELP: best-effort honesty fix (skip if upstream changed the line).
if [ "$(grep -cF "$HB_OLD" "$CMD" || true)" = "1" ]; then
  edit_once "$CMD" "$HB_OLD" "$HB_NEW"
fi

# POST-AUDIT — sentinel present; no native openai:/google: DEFAULT remains in
# either the DEFAULT_SLOTS block or the HELP override-default lines.
if ! grep -qF "$SENTINEL" "$RUNNER"; then
  echo "[gbrain-patch:cme-1] ERROR: post-apply audit failed — FIX-CME-1 sentinel absent in runner.ts after edit. FAILING THE BUILD." >&2
  exit 1
fi
if grep -qF "model: 'openai:gpt-4o'" "$RUNNER" || grep -qF "model: 'google:gemini-1.5-pro'" "$RUNNER"; then
  echo "[gbrain-patch:cme-1] ERROR: post-apply audit failed — a native openai:/google: DEFAULT_SLOTS id still present in runner.ts. FAILING THE BUILD." >&2
  exit 1
fi
if grep -qF "Override default 'openai:gpt-4o'" "$CMD" || grep -qF "Override default 'google:gemini-1.5-pro'" "$CMD"; then
  echo "[gbrain-patch:cme-1] ERROR: post-apply audit failed — a HELP line still documents a native openai:/google: default. FAILING THE BUILD." >&2
  exit 1
fi
# The override-flag plumbing MUST survive (operator opt-in to native diversity).
for needle in \
  "out.slotAModel = next;" \
  "out.slotBModel = next;" \
  "out.slotCModel = next;" \
  "parsed.slotAModel ?? DEFAULT_SLOTS[0]!.model" \
  "parsed.slotCModel ?? DEFAULT_SLOTS[2]!.model"; do
  if ! grep -qF "$needle" "$CMD"; then
    echo "[gbrain-patch:cme-1] ERROR: post-apply audit failed — override plumbing '$needle' missing from $CMD; the --slot-*-model opt-in must still work. FAILING THE BUILD." >&2
    exit 1
  fi
done
echo "[gbrain-patch:cme-1] ✓ applied: cross-modal eval defaults are now 3 distinct anthropic ids (all reroute to grok via FIX-NA-1, \$0); --slot-*-model overrides preserved."
echo "[gbrain-patch:cme-1] done."
