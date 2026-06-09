#!/usr/bin/env bash
# still_needed_probe for gbrain-mcp-tool-allowlist.
# Answers per upgrade: does serve-http still advertise the unfiltered tool list
# (operations.filter(op => !op.localOnly)) with NO native env allowlist / scope-
# filtered tool flag? If gbrain shipped a native MCP tool-allowlist, retire the
# patch. Conservative: prefer STILL-NEEDED.
# Exit 0 = still needed, 1 = obsolete (recommend retire), 2 = unknown.
set -uo pipefail
GBRAIN_SRC=""
for d in "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[mcp-probe] UNKNOWN: gbrain src tree not found." >&2
  exit 2
fi
T="$GBRAIN_SRC/commands/serve-http.ts"
[ -f "$T" ] || { echo "[mcp-probe] UNKNOWN: commands/serve-http.ts not found"; exit 2; }

# Patch anchor: the unfiltered tool-list definition. If gone, serve-http changed.
HAS_ANCHOR=$(grep -cF "operations.filter(op => !op.localOnly)" "$T" 2>/dev/null || echo 0)
if [ "$HAS_ANCHOR" -eq 0 ]; then
  echo "[mcp-probe] UNKNOWN: 'operations.filter(op => !op.localOnly)' anchor gone — serve-http changed; manual review."
  exit 2
fi

# Upstream-fix signal: gbrain added a native tool-allowlist env / scope-filtered
# tool list, OUTSIDE our __gbAllow patch marker.
UPSTREAM=0
if ! grep -qF '__gbAllow' "$T" 2>/dev/null; then
  if grep -qiE "GBRAIN_MCP_TOOLS|MCP_TOOLS|tool.?allow.?list|allowed.?tools|scope.*filter.*op|op.*filter.*scope" "$T" 2>/dev/null; then
    UPSTREAM=1
  fi
fi
echo "[mcp-probe] anchor:$HAS_ANCHOR upstream-allowlist:$UPSTREAM"

if [ "$UPSTREAM" -eq 1 ]; then
  echo "[mcp-probe] OBSOLETE: serve-http appears to ship a native MCP tool allowlist / scope-filtered tool list — review and retire the patch."
  exit 1
fi
echo "[mcp-probe] STILL NEEDED: serve-http advertises the unfiltered (op => !op.localOnly) tool list with no native allowlist."
exit 0
