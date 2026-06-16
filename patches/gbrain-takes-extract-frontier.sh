#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-takes-extract-frontier.sh   (VF FIX-TKF-1)
#
# WHY — `extractTakesFromPages()` (src/core/extract-takes-from-pages.ts) — the
# producer the FIX-TK-2 fork patch hooks to fence-project takes onto entity pages
# — selects eligible pages with NO "already has takes" filter:
#     WHERE type IN (...) AND deleted_at IS NULL
#       AND length(COALESCE(compiled_truth,'')) > 200
#     ORDER BY updated_at DESC LIMIT maxPages
# So EVERY run re-LLMs the same top-N recently-updated pages. The FIX-TK-2 fence
# claim-dedup makes a re-run WRITE-idempotent (no duplicate take rows), but it is
# NOT COST-idempotent: each re-scanned page is a fresh classifier call against the
# shared xAI-OAuth grok proxy. That is the #1 blocker to a recurring takes-drain
# cron (the analog of gbrain-atom-drain) — without a frontier filter, a cron would
# re-LLM the whole corpus every run and throttle the proxy.
#
# WHAT — add `AND NOT EXISTS (SELECT 1 FROM takes tk WHERE tk.page_id = pages.id)`
# to the eligible-pages query so a run only touches pages with ZERO takes. Makes
# every caller (the onboard bootstrap, the manual CLI, the new drain cron)
# cost-idempotent: re-runs skip already-extracted pages and only spend on net-new
# pages. No-op for the onboard takesCount===0 path (no takes exist → all pages
# pass). One-line WHERE addition; no param/signature change.
#
# ANCHOR (present EXACTLY ONCE):
#   "        AND length(COALESCE(compiled_truth, '')) > 200\n        ${sourceFilter}"
#
# gbrain *core* modification: build-time, baked, re-applied per GBRAIN_REF bump,
# idempotent (no-op if FIX-TKF-1 sentinel present), FAILS THE BUILD LOUDLY (old
# container keeps serving) on anchor drift. NOT filed upstream (operator decision
# 2026-06-16) — VF fork patch. See gbrain-takes-extract-frontier.meta.yml.
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
  echo "[gbrain-patch:tkf-1] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

CMD="$GBRAIN_SRC/core/extract-takes-from-pages.ts"
if [ ! -f "$CMD" ]; then
  echo "[gbrain-patch:tkf-1] ERROR: $CMD not found — gbrain moved the take extractor. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi
echo "[gbrain-patch:tkf-1] target: $CMD"

SENTINEL="FIX-TKF-1"
if grep -qF "$SENTINEL" "$CMD"; then
  echo "[gbrain-patch:tkf-1] ✓ already applied (FIX-TKF-1 sentinel present); no-op."
  exit 0
fi

OLD="        AND length(COALESCE(compiled_truth, '')) > 200
        \${sourceFilter}"
NEW="        AND length(COALESCE(compiled_truth, '')) > 200
        AND NOT EXISTS (SELECT 1 FROM takes tk WHERE tk.page_id = pages.id) -- ${SENTINEL}: frontier selector (only pages with zero takes) so re-runs are cost-idempotent / no re-LLM of already-extracted pages — enables the gbrain-takes-drain cron.
        \${sourceFilter}"

OLD="$OLD" NEW="$NEW" python3 - "$CMD" <<'PYEOF'
import os, sys
path=sys.argv[1]; old=os.environ['OLD']; new=os.environ['NEW']
s=open(path,encoding='utf-8').read(); n=s.count(old)
if n != 1:
    sys.stderr.write(f"[gbrain-patch:tkf-1] ERROR: anchor found {n} times (need exactly 1). gbrain changed the extractor query. RE-POINT. FAILING THE BUILD.\n")
    sys.exit(1)
open(path,'w',encoding='utf-8').write(s.replace(old,new))
PYEOF

# POST-AUDIT
if ! grep -qF "$SENTINEL" "$CMD"; then
  echo "[gbrain-patch:tkf-1] ERROR: post-apply audit — sentinel absent. FAILING THE BUILD." >&2; exit 1
fi
if ! grep -qF "NOT EXISTS (SELECT 1 FROM takes tk WHERE tk.page_id = pages.id)" "$CMD"; then
  echo "[gbrain-patch:tkf-1] ERROR: post-apply audit — NOT EXISTS frontier filter absent. FAILING THE BUILD." >&2; exit 1
fi
echo "[gbrain-patch:tkf-1] ✓ applied: extractTakesFromPages now skips pages that already have takes (cost-idempotent frontier selector)."
echo "[gbrain-patch:tkf-1] done."
