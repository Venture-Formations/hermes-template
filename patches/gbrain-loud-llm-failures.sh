#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-loud-llm-failures.sh   (VF FIX-LF-1)
#
# WHY THIS EXISTS
# The audit's "Face 2": gbrain swallows LLM/gateway failures into silent zeros.
# A throw inside chat() — or a chat gateway that reports unavailable because a
# model is set in the wrong config store — becomes `return []` with ZERO log
# lines, so a broken-config condition is indistinguishable from "nothing to
# extract." That is the generator of the 0-facts whack-a-mole: one symptom
# (facts:0, doctor green), many causes, surfaced serially.
#
# This patch makes the swallow LOUD. It does NOT change control flow (re-raising
# would break the put_page backstop). It injects a tagged, greppable
# `console.error` on each silent-return path so:
#   - the failure is visible in logs the moment it happens, and
#   - the gbrain-liveness cron / verify-upgrade can correlate facts=0 with a
#     real cause instead of a human eyeballing a count days later.
#
# Sites patched (this iteration): src/core/facts/extract.ts
#   (1) `if (!isAvailable('chat')) return []`  — the 0-facts-saga path
#   (2) chat() catch → `return []`              — provider/auth error swallow
# FOLLOW-UP (same mechanism, add when validated): src/core/facts/classify.ts
#   (cosine_fallback degrade) and src/core/extract-takes-from-pages.ts (catch
#   → continue). Tracked in the meta `why`; the anthropic-scan/liveness invariants
#   cover the AGGREGATE silent-zero until those anchors are added.
#
# Upstream-PR candidate: "don't swallow gateway auth/provider errors silently"
# is a clean contribution that would retire this patch (see deprecate_when).
#
# Applied at Docker BUILD; idempotent; FAILS THE BUILD LOUDLY (old container
# keeps serving) if an anchor moved — never a silent no-op. Python transform
# with fail-closed anchor assertions (container ships python3.12).
# ---------------------------------------------------------------------------
set -euo pipefail
SENTINEL='VF-FIX-LF-1'

GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[loud-llm] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
TARGET="$GBRAIN_SRC/core/facts/extract.ts"
echo "[loud-llm] target: $TARGET"
if [ ! -f "$TARGET" ]; then
  echo "[loud-llm] ERROR: $TARGET missing — gbrain moved the facts extractor. RE-POINT THIS PATCH. FAILING THE BUILD." >&2
  exit 1
fi

if grep -qF "$SENTINEL" "$TARGET"; then
  echo "[loud-llm] ✓ already applied ($SENTINEL present) — no-op."
  exit 0
fi

# Exact-string transform with fail-closed anchor assertions. A missing anchor is
# a LOUD build failure (RE-POINT), never a silent skip.
python3 - "$TARGET" <<'PYEOF'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()

edits = [
    ("isAvailable-swallow (0-facts-saga path)",
     "    // No chat gateway → no extraction. Caller still inserts facts via direct\n"
     "    // `gbrain take add` paths.\n"
     "    return [];",
     "    // No chat gateway → no extraction. Caller still inserts facts via direct\n"
     "    // `gbrain take add` paths.\n"
     "    // [VF-FIX-LF-1] make the silent zero LOUD (audit Face 2): a chat gateway\n"
     "    // reported unavailable is usually a config-store split (model set in DB but\n"
     "    // not in /data/.gbrain/config.json) or a missing provider key — not a real\n"
     "    // empty corpus. Log it so liveness/verify can correlate facts=0 with cause.\n"
     "    console.error('[VF-FIX-LF-1] facts.extract: chat gateway UNAVAILABLE -> 0 facts (check chat model config store + provider key)');\n"
     "    return [];"),
    ("chat-catch-swallow (provider/auth error)",
     "    if (isAbort(err)) throw err;\n"
     "    return [];",
     "    if (isAbort(err)) throw err;\n"
     "    // [VF-FIX-LF-1] make the silent zero LOUD: a swallowed chat() throw (auth,\n"
     "    // provider down, rate-lease, model-not-found) is indistinguishable from an\n"
     "    // empty corpus without this line.\n"
     "    console.error(`[VF-FIX-LF-1] facts.extract: chat() threw and was swallowed -> 0 facts this turn (model/provider/auth?): ${err instanceof Error ? err.message : String(err)}`);\n"
     "    return [];"),
]

for desc, old, new in edits:
    if old not in s:
        sys.stderr.write(f"[loud-llm] ERROR: anchor missing ({desc}) in facts/extract.ts — gbrain changed the swallow site. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD.\n")
        sys.exit(1)
    s = s.replace(old, new, 1)

open(path, 'w', encoding='utf-8').write(s)
print("[loud-llm] applied facts/extract.ts (2 sites)")
PYEOF

# Post-audit: both sentinel lines must be present (2 console.error injections).
COUNT=$(grep -cF "$SENTINEL" "$TARGET" || true)
if [ "${COUNT:-0}" -lt 2 ]; then
  echo "[loud-llm] ERROR: post-apply audit found $COUNT/2 sentinels — injection incomplete. FAILING THE BUILD." >&2
  exit 1
fi
echo "[loud-llm] ✓ applied: silent facts-extraction swallows now log a [$SENTINEL] line."
echo "[loud-llm] done."
