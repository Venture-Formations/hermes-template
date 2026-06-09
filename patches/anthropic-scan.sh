#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# anthropic-scan.sh — fail-closed behavioral guard for the no-native-Anthropic
# guarantee. Companion to gbrain-no-anthropic-reroute.sh (FIX-NA-1).
#
# This deployment provisions no ANTHROPIC_API_KEY. FIX-NA-1 re-routes native
# `anthropic:` ids at the single resolveRecipe chokepoint. This scanner proves
# that guarantee still holds after a build / upgrade, in two fail-closed checks:
#
#   (1) SENTINEL — the FIX-NA-1 reroute is present in model-resolver.ts.
#       Missing = the patch regressed (e.g. a runtime `bun install -g` wiped it,
#       or an upgrade moved the anchor and the patch silently skipped). LOUD FAIL.
#
#   (2) BYPASS — no native-Anthropic CLIENT construction site exists that is not
#       downstream of the rerouted chokepoint. Any un-allowlisted construction
#       (new Anthropic( / createAnthropic / @anthropic-ai/sdk / the
#       'native-anthropic' implementation dispatch) is a path that could reach
#       the Anthropic API directly — fail closed and name it for review.
#       Reviewed-safe sites live in anthropic-allowlist.txt WITH a reason.
#
# Runs (a) at Docker build right after the reroute patch, (b) in the WS4 CI
# dry-run against the candidate ref, and (c) in verify-upgrade.sh on-container.
# Exit 0 = guarantee holds; exit 1 = guarantee broken (caller treats as red).
# Optional arg: path to allowlist (default: alongside this script).
# ---------------------------------------------------------------------------
set -uo pipefail

SENTINEL='VF-FIX-NA-1'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ALLOWLIST="${1:-$SCRIPT_DIR/anthropic-allowlist.txt}"

GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[anthropic-scan] ERROR: gbrain src tree not found; cannot verify the guarantee." >&2
  exit 1
fi
echo "[anthropic-scan] target: $GBRAIN_SRC"

fail=0

# --- (1) SENTINEL: the reroute must be present -----------------------------
RESOLVER="$GBRAIN_SRC/core/ai/model-resolver.ts"
if grep -qF "$SENTINEL" "$RESOLVER" 2>/dev/null; then
  echo "[anthropic-scan] ✓ (1) FIX-NA-1 reroute sentinel present in model-resolver.ts"
else
  echo "[anthropic-scan] ✗ (1) FIX-NA-1 reroute MISSING from $RESOLVER" >&2
  echo "[anthropic-scan]     The no-native-Anthropic guarantee is OFF. Re-run gbrain-no-anthropic-reroute.sh." >&2
  fail=1
fi

# --- (2) BYPASS: no un-allowlisted native-Anthropic client construction -----
# Construction patterns (NOT inert `anthropic:` string literals).
PATTERN='new[[:space:]]+Anthropic\(|createAnthropic|@anthropic-ai/sdk|["'"'"']native-anthropic["'"'"']'
HITS=$(grep -rnE --include='*.ts' "$PATTERN" "$GBRAIN_SRC" 2>/dev/null || true)

# Build the allowlist substring set (skip blanks + comments).
LEAKS=""
if [ -n "$HITS" ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    allowed=0
    if [ -f "$ALLOWLIST" ]; then
      while IFS= read -r raw; do
        tok="${raw%%#*}"                       # strip inline comment
        tok="$(printf '%s' "$tok" | sed 's/[[:space:]]*$//;s/^[[:space:]]*//')"
        [ -z "$tok" ] && continue
        case "$hit" in *"$tok"*) allowed=1; break ;; esac
      done < "$ALLOWLIST"
    fi
    [ "$allowed" -eq 0 ] && LEAKS+="$hit"$'\n'
  done <<< "$HITS"
fi

if [ -n "${LEAKS//[$'\n']/}" ]; then
  echo "[anthropic-scan] ✗ (2) un-allowlisted native-Anthropic construction site(s):" >&2
  printf '%s' "$LEAKS" | sed '/^$/d;s/^/[anthropic-scan]   BYPASS: /' >&2
  echo "[anthropic-scan]     A path here can reach the Anthropic API directly, bypassing FIX-NA-1." >&2
  echo "[anthropic-scan]     REVIEW each: if it is the canonical adapter gated by resolveRecipe, add it" >&2
  echo "[anthropic-scan]     to anthropic-allowlist.txt WITH a reason; otherwise it must be patched." >&2
  fail=1
else
  echo "[anthropic-scan] ✓ (2) no un-allowlisted native-Anthropic construction sites"
fi

if [ "$fail" -ne 0 ]; then
  echo "[anthropic-scan] RESULT: FAIL — no-native-Anthropic guarantee is not proven. (fail-closed)" >&2
  exit 1
fi
echo "[anthropic-scan] RESULT: OK — no-native-Anthropic guarantee holds."
exit 0
