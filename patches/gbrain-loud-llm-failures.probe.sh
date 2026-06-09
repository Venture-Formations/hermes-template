#!/usr/bin/env bash
# still_needed_probe for FIX-LF-1. Answers per upgrade: did gbrain stop
# swallowing gateway failures silently (re-raise / log natively)? If so, retire.
# Exit 0 = still needed, 1 = obsolete (recommend retire), 2 = unknown.
set -uo pipefail
GBRAIN_SRC=""
for d in "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  [ -n "$d" ] && [ -d "$d" ] && { GBRAIN_SRC="$d"; break; }
done
T="$GBRAIN_SRC/core/facts/extract.ts"
[ -f "$T" ] || { echo "[lf-probe] UNKNOWN: facts/extract.ts not found"; exit 2; }

# The silent swallow exists if BOTH gates are present: the isAvailable('chat')
# short-circuit and the chat() catch that re-throws only aborts. (Our patch adds
# logging but KEEPS these gates, so this is stable on patched + vanilla trees.)
HAS_ISAVAIL=$(grep -c "isAvailable('chat')" "$T" 2>/dev/null || echo 0)
HAS_CATCH=$(grep -c "if (isAbort(err)) throw err;" "$T" 2>/dev/null || echo 0)
echo "[lf-probe] isAvailable('chat') gates: $HAS_ISAVAIL ; isAbort-rethrow catches: $HAS_CATCH"

if [ "$HAS_ISAVAIL" -ge 1 ] && [ "$HAS_CATCH" -ge 1 ]; then
  echo "[lf-probe] STILL NEEDED: facts.extract still short-circuits to [] on gateway-unavailable / swallows chat() throws."
  exit 0
fi
echo "[lf-probe] OBSOLETE: the facts.extract swallow gates changed — review whether gbrain now surfaces gateway failures natively, then retire FIX-LF-1."
exit 1
