#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-eval-takes-quality-gateway-env.sh   (VF FIX-TQ-1)
#
# WHY THIS EXISTS
# `gbrain eval takes-quality run` (our weekly `gbrain-eval-takes-quality-weekly`
# cron) self-configures the AI gateway in src/commands/eval-takes-quality.ts:
#     configureGateway({ ...cfg, ...(process.env as Record<string, string>) } as any);
# That spreads `process.env` as TOP-LEVEL keys, so the REQUIRED
# `AIGatewayConfig.env` field (src/core/ai/types.ts: "Env snapshot read once at
# configuration time. Gateway never reads process.env at call time.") is left
# UNDEFINED — the `as any` cast suppresses the type error that would catch it.
# Downstream, configureGateway sets `_config.env = config.env` (undefined), and
# the FIRST model call hits defaultResolveAuth(recipe, cfg.env=undefined, ...)
# which evaluates `env[k]` (gateway.ts) on `undefined` and throws:
#     provider_error: undefined is not an object (evaluating 'env[k]')
# for EVERY model in the panel -> 0 of 3 slots score -> verdict INCONCLUSIVE ->
# the command process.exit(2) -> the weekly cron is recorded FAILED every run,
# and take-quality is never actually measured. The sibling
# eval-cross-modal.ts:configureGatewayForCli() does it CORRECTLY with
# `env: { ...process.env }` — this is the pattern eval-takes-quality.ts was
# supposed to mirror (its own comment says "mirrors eval-cross-modal pattern").
#
# WHAT THIS PATCH DOES
# Replaces the one buggy configureGateway call so env is nested under the `env:`
# key (the exact shape configureGateway + every recipe's auth resolver expect):
#     configureGateway({ ...cfg, env: { ...process.env } } as any);
# Nothing else changes — the model fields still come from `...cfg`, the reroute
# to grok still happens at the FIX-NA-1 chokepoint. Validated live 2026-06-16:
# pre-fix the eval returns INCONCLUSIVE (0/3 models, `env[k]` error, exit 2);
# post-fix all 3/3 models score and the command returns a real verdict.
#
# ANCHOR (must be present EXACTLY ONCE):
#   src/commands/eval-takes-quality.ts:
#     configureGateway({ ...cfg, ...(process.env as Record<string, string>) } as any);
#
# This is a gbrain *core* modification. Applied at Docker BUILD time after the
# gbrain bake; baked into the image; re-applied on every GBRAIN_REF bump;
# idempotent (no-op if the FIX-TQ-1 sentinel is already present); FAILS THE
# BUILD LOUDLY (old container keeps serving — no outage) if the anchor
# moved/changed, forcing a re-point — never a silent no-op. See
# UPGRADING_GBRAIN.md. Filed upstream (clean 1-line fix; affects all users);
# retire when garrytan/gbrain fixes eval-takes-quality.ts's configureGateway call.
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
  echo "[gbrain-patch:tq-1] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

CMD="$GBRAIN_SRC/commands/eval-takes-quality.ts"
if [ ! -f "$CMD" ]; then
  echo "[gbrain-patch:tq-1] ERROR: $CMD not found — gbrain moved the takes-quality eval command. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD." >&2
  exit 1
fi
echo "[gbrain-patch:tq-1] target: $CMD"

SENTINEL="// FIX-TQ-1"

# Idempotent: already applied?
if grep -qF "$SENTINEL" "$CMD"; then
  echo "[gbrain-patch:tq-1] ✓ already applied (FIX-TQ-1 sentinel present); no-op."
  exit 0
fi

# --- ANCHOR (must be present EXACTLY ONCE) --------------------------------
OLD="  configureGateway({ ...cfg, ...(process.env as Record<string, string>) } as any);"
NEW="  configureGateway({ ...cfg, env: { ...process.env } } as any); ${SENTINEL} (hermes-template build patch): the vanilla line spread process.env as TOP-LEVEL keys, leaving the REQUIRED AIGatewayConfig.env field undefined (the \`as any\` cast hid it) -> _config.env undefined -> defaultResolveAuth reads env[k] on undefined -> 'undefined is not an object' for EVERY model -> 0/3 score -> INCONCLUSIVE/exit-2 every weekly run. Nest env under the env: key (mirrors the working eval-cross-modal.ts configureGatewayForCli pattern). See gbrain-eval-takes-quality-gateway-env.meta.yml."

n=$(grep -cF "$OLD" "$CMD" || true)
if [ "$n" -eq 0 ]; then
  echo "[gbrain-patch:tq-1] ERROR: anchor not found in $CMD:" >&2
  echo "[gbrain-patch:tq-1]   anchor: $OLD" >&2
  echo "[gbrain-patch:tq-1] gbrain changed the takes-quality gateway-config call. RE-POINT (UPGRADING_GBRAIN.md). FAILING THE BUILD (old container keeps serving)." >&2
  exit 1
elif [ "$n" -gt 1 ]; then
  echo "[gbrain-patch:tq-1] ERROR: anchor is AMBIGUOUS ($n matches) in $CMD — a precise splice needs exactly one site. RE-POINT. FAILING THE BUILD." >&2
  exit 1
fi

# APPLY — exact one-line replacement (Python exact .replace with count assert,
# mirroring FIX-CME-1 / FIX-AD-1 / FIX-TK-3).
OLD="$OLD" NEW="$NEW" python3 - "$CMD" <<'PYEOF'
import os, sys
path = sys.argv[1]
old = os.environ['OLD']
new = os.environ['NEW']
s = open(path, encoding='utf-8').read()
if s.count(old) != 1:
    sys.stderr.write("[gbrain-patch:tq-1] ERROR(py): expected exactly 1 occurrence of the anchor in %s, found %d. FAILING.\n" % (path, s.count(old)))
    sys.exit(1)
open(path, 'w', encoding='utf-8').write(s.replace(old, new))
PYEOF

# POST-AUDIT — sentinel present; the buggy top-level spread is gone; the nested
# env form is present.
if ! grep -qF "$SENTINEL" "$CMD"; then
  echo "[gbrain-patch:tq-1] ERROR: post-apply audit failed — FIX-TQ-1 sentinel absent after edit. FAILING THE BUILD." >&2
  exit 1
fi
if grep -qF "...cfg, ...(process.env as Record<string, string>) } as any);" "$CMD"; then
  echo "[gbrain-patch:tq-1] ERROR: post-apply audit failed — the buggy top-level process.env spread is still present. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF "configureGateway({ ...cfg, env: { ...process.env } } as any);" "$CMD"; then
  echo "[gbrain-patch:tq-1] ERROR: post-apply audit failed — the nested 'env: { ...process.env }' form is absent. FAILING THE BUILD." >&2
  exit 1
fi
echo "[gbrain-patch:tq-1] ✓ applied: eval-takes-quality.ts configureGateway now nests env under env: — takes-quality eval can reach a verdict (no more INCONCLUSIVE/env[k] crash)."
echo "[gbrain-patch:tq-1] done."
