#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-subagent-no-native-anthropic.probe.sh   (still_needed_probe for FIX-NA-2)
#
# Answers, per upgrade, the ONE question: "did gbrain stop letting the subagent
# loop build a native Anthropic client outside the gateway, so FIX-NA-2 can be
# retired?" Run by the WS4 CI dry-run against the VANILLA (un-patched) candidate
# tree, and by verify-upgrade.sh on-container.
#
# The underlying issue FIX-NA-2 exists for: the subagent handler defaults to
# `() => new Anthropic()` — a DIRECT native client construction that does NOT go
# through resolveRecipe (so FIX-NA-1 cannot reroute it). The patch is OBSOLETE
# the day gbrain routes the subagent loop through the gateway / resolveRecipe
# (the native `new Anthropic()` default disappears).
#
# Exit codes (the harness contract for every *.probe.sh):
#   0 = STILL NEEDED  — the native fallback reproduces on this ref; keep the patch
#   1 = OBSOLETE      — upstream addressed it; recommend retirement (recommend-only)
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
  echo "[na2-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

T="$GBRAIN_SRC/core/minions/handlers/subagent.ts"
[ -f "$T" ] || { echo "[na2-probe] UNKNOWN: minions/handlers/subagent.ts not found"; exit 2; }

# Signal: the native fallback factory still constructs `new Anthropic()` as the
# default for makeAnthropic. Matches both the vanilla one-liner and our patched
# guarded form (which still `return new Anthropic()` past the key check).
HAS_FALLBACK=$(grep -cE 'makeAnthropic|new Anthropic\(\)' "$T" 2>/dev/null | head -1 | tr -d ' ')
HAS_NATIVE=$(grep -cF 'new Anthropic()' "$T" 2>/dev/null | head -1 | tr -d ' ')
HAS_FALLBACK="${HAS_FALLBACK:-0}"
HAS_NATIVE="${HAS_NATIVE:-0}"
echo "[na2-probe] makeAnthropic/native refs: $HAS_FALLBACK ; native new Anthropic() construction: $HAS_NATIVE"

if [ "$HAS_NATIVE" -ge 1 ]; then
  echo "[na2-probe] STILL NEEDED: subagent loop still constructs a native Anthropic client outside the gateway."
  exit 0
fi
echo "[na2-probe] OBSOLETE: no native new Anthropic() construction in subagent.ts — gbrain likely routes the subagent loop through the gateway. Review and retire FIX-NA-2."
exit 1
