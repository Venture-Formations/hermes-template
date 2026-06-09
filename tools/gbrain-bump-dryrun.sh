#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-bump-dryrun.sh — pre-bump gate for the gbrain daily update watcher.
#
# gbrain is updated AUTOMATICALLY: the "gbrain daily update watcher" routine
# bumps `ARG GBRAIN_REF` in the Dockerfile and pushes DIRECTLY to
# deploy/venture-formations-fork (no PR) → Railway rebuilds. The only safety is
# the fail-closed Docker build. This script is the gate the routine runs BEFORE
# pushing: it proves the candidate gbrain ref still takes all our patches, so a
# bad bump is never even committed (cleaner than a red prod build), and it
# reports per-patch obsolescence (retire candidates) along the way.
#
# It replicates the Dockerfile patch-application steps WITHOUT Docker: installs
# the candidate gbrain to a throwaway bun prefix, runs every patches/*.probe.sh
# against the vanilla tree (obsolescence matrix), then applies every patch +
# anthropic-scan + `gbrain --version`. Exit 0 = GREEN (safe to bump); non-zero =
# RED (names the failing patch — re-point it before bumping).
#
# Usage:  tools/gbrain-bump-dryrun.sh <candidate-gbrain-sha|master>
# Run from the hermes-template repo root (the routine's checkout).
# ---------------------------------------------------------------------------
set -uo pipefail
REF="${1:?usage: gbrain-bump-dryrun.sh <candidate-gbrain-sha|master>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PATCHES="$ROOT/patches"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RED=0
say() { echo "[bump-dryrun] $*"; }

# --- ensure bun (cloud routine env may not ship it) ------------------------
if ! command -v bun >/dev/null 2>&1; then
  say "installing bun…"
  curl -fsSL https://bun.sh/install | BUN_INSTALL="$TMP/buninstall" bash >/dev/null 2>&1 || true
  export PATH="$TMP/buninstall/bin:$PATH"
fi
command -v bun >/dev/null 2>&1 || { say "FATAL: bun unavailable; cannot dry-run."; exit 3; }

# --- install candidate gbrain to a throwaway prefix ------------------------
export BUN_INSTALL="$TMP/bun"
say "installing gbrain@$REF to a throwaway prefix…"
if ! bun install -g "github:garrytan/gbrain#$REF" >/dev/null 2>&1; then
  say "FATAL: bun install of gbrain@$REF failed (bad ref / network). NOT safe to bump."
  exit 3
fi
GBRAIN_BIN="$BUN_INSTALL/bin/gbrain"
GBRAIN_SRC="$BUN_INSTALL/install/global/node_modules/gbrain/src"
[ -d "$GBRAIN_SRC" ] || { say "FATAL: gbrain src tree not found after install."; exit 3; }
VER="$("$GBRAIN_BIN" --version 2>/dev/null | head -1)"
say "candidate: $VER ($REF)"

# --- (A) per-patch obsolescence matrix (run probes vs the VANILLA tree) -----
say "── per-patch obsolescence matrix (vanilla tree) ──"
OBSOLETE=()
for probe in "$PATCHES"/*.probe.sh; do
  [ -f "$probe" ] || continue
  id="$(basename "$probe" .probe.sh)"
  GBRAIN_SRC_OVERRIDE="$GBRAIN_SRC" bash "$probe" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) say "  KEEP     $id" ;;
    1) say "  OBSOLETE $id  ← upstream may have fixed this; review for retirement"; OBSOLETE+=("$id") ;;
    *) say "  UNKNOWN  $id  (probe rc=$rc)" ;;
  esac
done

# --- (B) apply every patch + scan + version (the real gate) ----------------
say "── applying patches to the candidate tree ──"
for sh in "$PATCHES"/gbrain-*.sh; do
  case "$sh" in *.probe.sh) continue ;; esac
  [ -f "$sh" ] || continue
  id="$(basename "$sh" .sh)"
  if bash "$sh" >/dev/null 2>&1; then
    say "  ✓ $id"
  else
    say "  ✗ $id — ANCHOR MOVED / patch failed on $VER. RE-POINT before bumping."
    RED=1
  fi
done
if [ -f "$PATCHES/anthropic-scan.sh" ]; then
  if bash "$PATCHES/anthropic-scan.sh" >/dev/null 2>&1; then
    say "  ✓ anthropic-scan (no-native-anthropic guarantee holds)"
  else
    say "  ✗ anthropic-scan FAILED — a new native-Anthropic construction site or a wiped reroute on $VER. Review before bumping."
    RED=1
  fi
fi
if "$GBRAIN_BIN" --version >/dev/null 2>&1; then
  say "  ✓ gbrain --version loads the patched tree"
else
  say "  ✗ gbrain --version FAILED on the patched tree."
  RED=1
fi

# --- verdict ----------------------------------------------------------------
echo
if [ "$RED" -ne 0 ]; then
  say "RESULT: RED — do NOT bump to $REF. A patch needs re-pointing (see ✗ above)."
  exit 1
fi
if [ "${#OBSOLETE[@]}" -gt 0 ]; then
  say "RESULT: GREEN — safe to bump to $REF ($VER). Note OBSOLETE (recommend-only retire): ${OBSOLETE[*]}"
else
  say "RESULT: GREEN — safe to bump to $REF ($VER). All patches apply; no obsolete patches."
fi
exit 0
