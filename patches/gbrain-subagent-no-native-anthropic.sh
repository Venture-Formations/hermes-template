#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-subagent-no-native-anthropic.sh   (VF FIX-NA-2)
#
# WHY THIS EXISTS
# FIX-NA-1 closes the MODEL-RESOLVER chokepoint (resolveRecipe reroutes native
# `anthropic:` ids → openrouter:auto when no ANTHROPIC_API_KEY). But the subagent
# LLM loop's LEGACY path does NOT go through that chokepoint: it constructs an
# Anthropic SDK client DIRECTLY via a default factory —
#
#     const makeAnthropic = deps.makeAnthropic ?? (() => new Anthropic());
#     const client: MessagesClient = deps.client ?? makeAnthropic().messages;
#
# On this deployment (NO ANTHROPIC_API_KEY provisioned) that `new Anthropic()`
# default would build a native client and reach the Anthropic API directly,
# bypassing FIX-NA-1.
#
# ── THE BUG THIS REVISION FIXES (the queue-wedge RCA, 2026-06-09) ───────────
# The PRIOR version of this patch made the `makeAnthropic` default factory THROW
# when no key was set. But `makeSubagentHandler` invokes that factory EAGERLY at
# handler-CONSTRUCTION time (`const client = deps.client ?? makeAnthropic().messages`),
# which runs at `worker.register('subagent', makeSubagentHandler({ engine }))` on
# EVERY worker startup — BEFORE any job dispatches and REGARDLESS of which loop
# path (gateway vs legacy) a job will take. So the throw fired at registration and
# crashed the worker ~2.4s after spawn, every spawn → child-worker-supervisor hit
# maxCrashes → autopilot gave up → the `default` queue WEDGED (jobs waiting, 0
# active, worker "alive but not claiming"). The guard's own remediation
# (models.tier.subagent=openrouter:auto) was a no-op because the guard keys off the
# MISSING KEY, not the tier config, and because the gateway loop ALSO died at the
# same eager construction.
#
# ── THE FIX: defer construction; never throw at registration ────────────────
# gbrain v0.38+ has a GATEWAY-native subagent loop (`agent.use_gateway_loop=true`)
# that is provider-agnostic and routes EVERY model string through resolveRecipe —
# so FIX-NA-1 already reroutes it to openrouter:auto. The gateway path NEVER touches
# the native `client` (it early-returns via runSubagentViaGateway before the legacy
# replay code that calls `client.create(...)`). Upstream's own gateway-path E2E test
# proves this: it stubs makeAnthropic to a throwing function and asserts the legacy
# path is never invoked.
#
# This revision makes the native client LAZY:
#   * `makeAnthropic` default still THROWS a tagged, greppable Error when no key —
#     but it is no longer invoked eagerly.
#   * `client` becomes a lazy Proxy that constructs `makeAnthropic().messages` on
#     FIRST PROPERTY ACCESS. The unpatched legacy call site `client.create(...)` is
#     unchanged; the gateway path never accesses `client`, so it never constructs.
# Net: with `agent.use_gateway_loop=true` and no key, the worker registers cleanly,
# the queue drains via the gateway→openrouter path, and the legacy native path STILL
# fails LOUD (tagged, named for review) if it is ever actually reached without a key.
# With a key present, or an explicit deps.makeAnthropic/deps.client, behavior is
# unchanged.
#
# Site patched: src/core/minions/handlers/subagent.ts
#   const makeAnthropic = deps.makeAnthropic ?? (() => new Anthropic());
#   const client: MessagesClient = deps.client ?? makeAnthropic().messages;
#
# Applied at Docker BUILD; idempotent; FAILS THE BUILD LOUDLY (old container
# keeps serving) if the anchor moved — never a silent no-op. Python transform
# with fail-closed anchor assertions (container ships python3.12).
#
# NOTE: this patch must be paired with the live/baked config `agent.use_gateway_loop
# = true` (set via `gbrain config set agent.use_gateway_loop true`). The patch alone
# stops the worker CRASH; the flag is what routes the loop through the gateway so it
# actually runs on openrouter instead of hitting the (now-lazy, still-loud) native
# legacy path. See hermes-workspace OPERATIONS_LOG.md.
# ---------------------------------------------------------------------------
set -euo pipefail
SENTINEL='VF-FIX-NA-2'

GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[subagent-na2] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
TARGET="$GBRAIN_SRC/core/minions/handlers/subagent.ts"
echo "[subagent-na2] target: $TARGET"
if [ ! -f "$TARGET" ]; then
  echo "[subagent-na2] ERROR: $TARGET missing — gbrain moved the subagent handler. RE-POINT THIS PATCH. FAILING THE BUILD." >&2
  exit 1
fi

if grep -qF "$SENTINEL" "$TARGET"; then
  echo "[subagent-na2] ✓ already applied ($SENTINEL present) — no-op."
  exit 0
fi

# Exact-string transform with a fail-closed anchor assertion. A missing anchor is
# a LOUD build failure (RE-POINT), never a silent skip.
python3 - "$TARGET" <<'PYEOF'
import sys
path = sys.argv[1]
s = open(path, encoding='utf-8').read()

OLD = (
    "  const makeAnthropic = deps.makeAnthropic ?? (() => new Anthropic());\n"
    "  const client: MessagesClient = deps.client ?? makeAnthropic().messages;"
)
NEW = (
    "  // [VF-FIX-NA-2] This deployment provisions NO ANTHROPIC_API_KEY. The subagent\n"
    "  // loop's LEGACY path builds its Anthropic client DIRECTLY here — it does NOT go\n"
    "  // through resolveRecipe (FIX-NA-1), so the `() => new Anthropic()` default would\n"
    "  // reach the Anthropic API directly, bypassing the no-native guarantee.\n"
    "  //\n"
    "  // CRITICAL: this client used to be constructed EAGERLY at handler-construction\n"
    "  // time (`makeSubagentHandler` runs at every worker.register on worker startup,\n"
    "  // BEFORE any job and regardless of gateway-vs-legacy path). A throw here wedged\n"
    "  // the whole job queue (worker crash-loop → autopilot gives up → queue stuck).\n"
    "  // So: (1) the default factory THROWS a tagged, greppable Error when no key is\n"
    "  // set — loud, named for review — but (2) the client is now LAZY: it constructs\n"
    "  // (and only then can throw) on FIRST PROPERTY ACCESS, which only the legacy\n"
    "  // replay path does (via client.create). The gateway-native loop\n"
    "  // (agent.use_gateway_loop=true, routed through resolveRecipe → openrouter:auto)\n"
    "  // NEVER touches this client, so a no-key gateway deployment registers + drains\n"
    "  // cleanly. With a key present, or explicit deps.client / deps.makeAnthropic,\n"
    "  // behavior is unchanged. Routing the legacy loop through the gateway is the\n"
    "  // upstream fix.\n"
    "  const makeAnthropic =\n"
    "    deps.makeAnthropic ??\n"
    "    (() => {\n"
    "      if (!process.env.ANTHROPIC_API_KEY) {\n"
    "        throw new Error(\n"
    "          \"ERR_NATIVE_ANTHROPIC_BLOCKED [VF-FIX-NA-2]: subagent loop must not \" +\n"
    "            \"construct a native Anthropic client without a key; enable the gateway \" +\n"
    "            \"loop (gbrain config set agent.use_gateway_loop true) so it routes \" +\n"
    "            \"through resolveRecipe → openrouter:auto\",\n"
    "        );\n"
    "      }\n"
    "      return new Anthropic();\n"
    "    });\n"
    "  // Lazy native client: deferred construction on first property access. The\n"
    "  // gateway path never reads this Proxy, so makeAnthropic() (and its no-key\n"
    "  // throw) only fire if the legacy native path is actually exercised.\n"
    "  let __vfNativeClient: MessagesClient | undefined;\n"
    "  const client: MessagesClient =\n"
    "    deps.client ??\n"
    "    (new Proxy(\n"
    "      {},\n"
    "      {\n"
    "        get(_t, prop, recv) {\n"
    "          if (!__vfNativeClient) __vfNativeClient = makeAnthropic().messages;\n"
    "          const v = Reflect.get(\n"
    "            __vfNativeClient as object,\n"
    "            prop,\n"
    "            recv,\n"
    "          );\n"
    "          return typeof v === 'function'\n"
    "            ? (v as (...a: unknown[]) => unknown).bind(__vfNativeClient)\n"
    "            : v;\n"
    "        },\n"
    "      },\n"
    "    ) as MessagesClient);"
)

if OLD not in s:
    sys.stderr.write("[subagent-na2] ERROR: anchor missing (the two-line makeAnthropic/client default-construction block) in minions/handlers/subagent.ts — gbrain changed the native fallback / client-construction site. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD.\n")
    sys.exit(1)

s = s.replace(OLD, NEW, 1)
open(path, 'w', encoding='utf-8').write(s)
print("[subagent-na2] applied minions/handlers/subagent.ts (lazy native client + tagged guard)")
PYEOF

# Post-audit: the sentinel guard must be present (the throw injection landed).
COUNT=$(grep -cF "$SENTINEL" "$TARGET" || true)
if [ "${COUNT:-0}" -lt 1 ]; then
  echo "[subagent-na2] ERROR: post-apply audit found $COUNT/1 sentinels — injection failed. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF 'ERR_NATIVE_ANTHROPIC_BLOCKED' "$TARGET"; then
  echo "[subagent-na2] ERROR: post-apply audit: tagged Error not present — injection incomplete. FAILING THE BUILD." >&2
  exit 1
fi
# Post-audit: the client must now be lazy (Proxy), i.e. NOT eagerly invoking the
# factory. A residual eager `makeAnthropic().messages` would re-introduce the wedge.
if grep -qF 'deps.client ?? makeAnthropic().messages' "$TARGET"; then
  echo "[subagent-na2] ERROR: post-apply audit: eager 'deps.client ?? makeAnthropic().messages' still present — lazy client did not land. FAILING THE BUILD." >&2
  exit 1
fi
if ! grep -qF '__vfNativeClient' "$TARGET"; then
  echo "[subagent-na2] ERROR: post-apply audit: lazy client Proxy ('__vfNativeClient') not present — injection incomplete. FAILING THE BUILD." >&2
  exit 1
fi
echo "[subagent-na2] ✓ applied: subagent native-Anthropic client is now LAZY (constructs on first use); throws [$SENTINEL] only if the legacy path runs with no ANTHROPIC_API_KEY."
echo "[subagent-na2] done."
