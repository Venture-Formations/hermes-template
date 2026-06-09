#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-loud-llm-failures.sh   (VF FIX-LF-1)
#
# WHY THIS EXISTS
# The audit's "Face 2": gbrain swallows LLM/gateway failures into silent zeros.
# A throw inside chat() — or a chat gateway that reports unavailable because a
# model is set in the wrong config store — becomes `return []` (or a silent
# cosine_fallback degrade, or a per-page `continue`) with ZERO log lines, so a
# broken-config condition is indistinguishable from "nothing to extract." That
# is the generator of the 0-facts whack-a-mole: one symptom (facts:0, doctor
# green), many causes, surfaced serially.
#
# This patch makes the swallow LOUD. It does NOT change control flow (re-raising
# would break the put_page backstop / the cosine fallback / per-page progress).
# It injects a tagged, greppable `console.error` on each silent-degrade path so:
#   - the failure is visible in logs the moment it happens, and
#   - the gbrain-liveness cron / verify-upgrade can correlate facts=0 with a
#     real cause instead of a human eyeballing a count days later.
#
# Sites patched (4 total, across 3 files):
#   src/core/facts/extract.ts
#     (1) `if (!isAvailable('chat')) return []`  — the 0-facts-saga path
#     (2) chat() catch → `return []`              — provider/auth error swallow
#   src/core/facts/classify.ts
#     (3) chat() catch → cosine_fallback degrade  — classifier dropped silently
#   src/core/extract-takes-from-pages.ts
#     (4) per-page chat() catch → `continue`      — takes-extraction swallow
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

EXTRACT="$GBRAIN_SRC/core/facts/extract.ts"
CLASSIFY="$GBRAIN_SRC/core/facts/classify.ts"
TAKES="$GBRAIN_SRC/core/extract-takes-from-pages.ts"
echo "[loud-llm] targets:"
echo "[loud-llm]   $EXTRACT"
echo "[loud-llm]   $CLASSIFY"
echo "[loud-llm]   $TAKES"

for f in "$EXTRACT" "$CLASSIFY" "$TAKES"; do
  if [ ! -f "$f" ]; then
    echo "[loud-llm] ERROR: $f missing — gbrain moved a swallow site. RE-POINT THIS PATCH. FAILING THE BUILD." >&2
    exit 1
  fi
done

# Already-applied check: all three files must carry the sentinel for a no-op.
ALREADY=1
for f in "$EXTRACT" "$CLASSIFY" "$TAKES"; do
  if ! grep -qF "$SENTINEL" "$f"; then ALREADY=0; break; fi
done
if [ "$ALREADY" -eq 1 ]; then
  echo "[loud-llm] ✓ already applied ($SENTINEL present in all targets) — no-op."
  exit 0
fi

# Exact-string transform with fail-closed anchor assertions. A missing anchor is
# a LOUD build failure (RE-POINT), never a silent skip. One Python pass loops
# over the three target files; each edit asserts its anchor before replacing.
python3 - "$EXTRACT" "$CLASSIFY" "$TAKES" <<'PYEOF'
import sys

extract_path, classify_path, takes_path = sys.argv[1], sys.argv[2], sys.argv[3]

# file -> list of (desc, old, new). Each `old` is an EXACT anchor copied from
# garrytan/gbrain@1eb430a; a missing anchor fails the build.
plan = {
    extract_path: [
        ("facts.extract isAvailable-swallow (0-facts-saga path)",
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
        ("facts.extract chat-catch-swallow (provider/auth error)",
         "    if (isAbort(err)) throw err;\n"
         "    return [];",
         "    if (isAbort(err)) throw err;\n"
         "    // [VF-FIX-LF-1] make the silent zero LOUD: a swallowed chat() throw (auth,\n"
         "    // provider down, rate-lease, model-not-found) is indistinguishable from an\n"
         "    // empty corpus without this line.\n"
         "    console.error(`[VF-FIX-LF-1] facts.extract: chat() threw and was swallowed -> 0 facts this turn (model/provider/auth?): ${err instanceof Error ? err.message : String(err)}`);\n"
         "    return [];"),
    ],
    classify_path: [
        ("facts.classify chat-catch cosine_fallback degrade",
         "  } catch (err) {\n"
         "    // Classifier dropped (timeout, rate limit, refusal mapped to throw).\n"
         "    // Fall back to cosine.\n"
         "    if (topId !== null && topScore >= fallback) {",
         "  } catch (err) {\n"
         "    // Classifier dropped (timeout, rate limit, refusal mapped to throw).\n"
         "    // Fall back to cosine.\n"
         "    // [VF-FIX-LF-1] make the silent degrade LOUD: the classifier chat() throw\n"
         "    // is swallowed into a cosine_fallback (or INSERT) with zero log lines, so a\n"
         "    // broken chat config silently disables LLM dedup. Log without changing flow.\n"
         "    console.error(`[VF-FIX-LF-1] facts.classify: classifier chat() threw -> cosine_fallback degrade (model/provider/auth?): ${err instanceof Error ? err.message : String(err)}`);\n"
         "    if (topId !== null && topScore >= fallback) {"),
    ],
    takes_path: [
        ("extract-takes per-page chat-catch continue",
         "    } catch {\n"
         "      // Skip pages whose chat call fails (rate limit, content filter,\n"
         "      // transient error). Per-page progress continues.\n"
         "      continue;\n"
         "    }",
         "    } catch (err) {\n"
         "      // Skip pages whose chat call fails (rate limit, content filter,\n"
         "      // transient error). Per-page progress continues.\n"
         "      // [VF-FIX-LF-1] make the silent skip LOUD: a swallowed chat() throw here\n"
         "      // is indistinguishable from a page with no claims; a broken chat config\n"
         "      // silently extracts 0 takes. Log without changing per-page flow.\n"
         "      console.error(`[VF-FIX-LF-1] extract-takes: chat() threw, skipping page -> 0 takes this page (model/provider/auth?): ${err instanceof Error ? err.message : String(err)}`);\n"
         "      continue;\n"
         "    }"),
    ],
}

for path, edits in plan.items():
    s = open(path, encoding='utf-8').read()
    for desc, old, new in edits:
        if old not in s:
            sys.stderr.write(
                f"[loud-llm] ERROR: anchor missing ({desc}) in {path} — gbrain changed "
                f"the swallow site. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD.\n"
            )
            sys.exit(1)
        s = s.replace(old, new, 1)
    open(path, 'w', encoding='utf-8').write(s)
    print(f"[loud-llm] applied {path} ({len(edits)} site(s))")
PYEOF

# Post-audit: 4 sentinel console.error injections total across the three files.
COUNT=0
for f in "$EXTRACT" "$CLASSIFY" "$TAKES"; do
  c=$(grep -cF "$SENTINEL" "$f" || true)
  COUNT=$((COUNT + ${c:-0}))
done
if [ "$COUNT" -lt 4 ]; then
  echo "[loud-llm] ERROR: post-apply audit found $COUNT/4 sentinels — injection incomplete. FAILING THE BUILD." >&2
  exit 1
fi
echo "[loud-llm] ✓ applied: silent facts/classify/takes swallows now log a [$SENTINEL] line (4 sites)."
echo "[loud-llm] done."
