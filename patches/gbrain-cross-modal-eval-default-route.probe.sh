#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-cross-modal-eval-default-route.probe.sh  (still_needed_probe FIX-CME-1)
#
# Answers, per upgrade, "do the `gbrain eval cross-modal` defaults still bill a
# native provider, so this reroute patch is still needed?" Run against the
# VANILLA (un-patched) candidate tree.
#
# The issue: DEFAULT_SLOTS (src/core/cross-modal-eval/runner.ts) defaults slot A
# to `openai:gpt-4o` (native OPENAI_API_KEY) and slot C to
# `google:gemini-1.5-pro` (native Google key); only slot B (`anthropic:`) is
# rerouted to grok by FIX-NA-1. STILL NEEDED while those native defaults exist.
# OBSOLETE the day upstream makes the defaults provider-agnostic / non-native.
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
  echo "[cme-1-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi

RUNNER="$GBRAIN_SRC/core/cross-modal-eval/runner.ts"
if [ ! -f "$RUNNER" ]; then
  echo "[cme-1-probe] UNKNOWN: cross-modal-eval/runner.ts not found — eval restructured; manual review." >&2
  exit 2
fi

# Native defaults verbatim. If either is still a DEFAULT_SLOTS id, the leak exists.
if grep -qF "model: 'openai:gpt-4o'" "$RUNNER" || grep -qF "model: 'google:gemini-1.5-pro'" "$RUNNER"; then
  echo "[cme-1-probe] STILL NEEDED: DEFAULT_SLOTS still defaults a slot to native openai:gpt-4o / google:gemini-1.5-pro — a default \`gbrain eval cross-modal\` run would bill the native OPENAI_API_KEY / Google key."
  exit 0
fi

# Native openai:/google: defaults gone but a DEFAULT_SLOTS block still present →
# upstream changed the defaults; review whether the reroute is still warranted.
if grep -qF "DEFAULT_SLOTS" "$RUNNER"; then
  echo "[cme-1-probe] OBSOLETE: native openai:/google: defaults are gone from DEFAULT_SLOTS — upstream changed the cross-modal eval defaults; review and retire FIX-CME-1."
  exit 1
fi

echo "[cme-1-probe] UNKNOWN: neither the native defaults nor a DEFAULT_SLOTS block present — runner shape changed; manual review." >&2
exit 2
