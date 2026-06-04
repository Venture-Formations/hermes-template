#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-mcp-tool-allowlist.sh
#
# WHY THIS EXISTS
# `gbrain serve --http` advertises EVERY non-localOnly operation over MCP
# (~81 tools) to every authenticated client. The tool list is NOT filtered by
# OAuth scope (scope is enforced only at call time — see serve-http.ts
# CallToolRequestSchema), and gbrain ships NO flag to expose a subset. An 81-tool
# surface bloats client context and hurts tool selection, and the operator wants
# the brain to present a small, curated retrieval-focused tool set.
#
# WHAT IT DOES
# Patches the single line in serve-http.ts:
#     const mcpOperations = operations.filter(op => !op.localOnly);
# to additionally honor an optional GBRAIN_MCP_TOOLS env allowlist
# (comma-separated op names). When the env var is set, only those tools are
# advertised + callable; when unset, behavior is unchanged (all non-local ops).
# So the exposed tool set is controlled at runtime via a Railway service var —
# edit GBRAIN_MCP_TOOLS to change it, no rebuild needed for list changes.
#
# This is a gbrain CORE modification. The authoritative, GENERATED registry of
# every modification we carry (and why each exists) is
# hermes-workspace/MODIFICATIONS.md — never hand-maintain a count of core patches
# in prose. Applied at Docker BUILD time, baked into the image, re-applied on
# every GBRAIN_REF bump. Idempotent (no-op if already patched).
#
# ⚠️ VALIDATE ON EVERY gbrain UPGRADE: this patch anchors on the exact
# `operations.filter(op => !op.localOnly)` line in serve-http.ts. If a gbrain
# release renames/moves that line, this script EXITS NON-ZERO and FAILS THE
# BUILD (the old container keeps serving — no outage) so you are forced to
# re-point the anchor. See UPGRADING_GBRAIN.md. Do not silently ignore.
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolve the gbrain source tree across build + runtime layouts (mirrors
# gbrain-openrouter-model-defaults.sh).
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[gbrain-mcp-allowlist] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
FILE="$GBRAIN_SRC/commands/serve-http.ts"
echo "[gbrain-mcp-allowlist] target: $FILE"

if [ ! -f "$FILE" ]; then
  echo "[gbrain-mcp-allowlist] ERROR: serve-http.ts not found — gbrain layout changed. UPDATE THIS PATCH." >&2
  exit 1
fi

# Idempotent: our marker token already present means a prior run patched it.
if grep -qF "__gbAllow" "$FILE"; then
  echo "[gbrain-mcp-allowlist] already patched (__gbAllow present) — no-op."
  exit 0
fi

ANCHOR='const mcpOperations = operations.filter(op => !op.localOnly);'
# Single-line replacement. CRITICAL: the replacement must contain NO unescaped
# `&` (sed expands it to the whole match), no `@` (our delimiter), and no `\`.
# We therefore use a block-body filter (`if/return`) instead of `&&`/`||` to
# sidestep `&` entirely. Bash double-quotes here are fine (the JS string literals
# inside use single quotes; there are no double quotes in the replacement).
REPLACE="const __gbAllow = process.env.GBRAIN_MCP_TOOLS ? new Set(process.env.GBRAIN_MCP_TOOLS.split(',').map(s => s.trim()).filter(Boolean)) : null; const mcpOperations = operations.filter(op => { if (op.localOnly) return false; if (__gbAllow) return __gbAllow.has(op.name); return true; });"

if ! grep -qF "$ANCHOR" "$FILE"; then
  echo "[gbrain-mcp-allowlist] ERROR: anchor not found:" >&2
  echo "[gbrain-mcp-allowlist]   $ANCHOR" >&2
  echo "[gbrain-mcp-allowlist] gbrain changed the mcpOperations definition — RE-POINT THIS PATCH (see UPGRADING_GBRAIN.md)." >&2
  exit 1
fi

sed -i "s@${ANCHOR}@${REPLACE}@" "$FILE"

# Post-patch audit — fail the build loudly if the rewrite didn't land.
if ! grep -qF "__gbAllow" "$FILE"; then
  echo "[gbrain-mcp-allowlist] ERROR: post-patch audit failed (__gbAllow absent after sed)." >&2
  exit 1
fi
echo "[gbrain-mcp-allowlist] ✓ serve --http now honors the GBRAIN_MCP_TOOLS allowlist."
echo "[gbrain-mcp-allowlist]   (unset = all tools; set = comma-separated op names)"
