#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-subagent-no-native-anthropic.sh   (VF FIX-NA-2)
#
# WHY THIS EXISTS
# FIX-NA-1 closes the MODEL-RESOLVER chokepoint (resolveRecipe reroutes native
# `anthropic:` ids → openrouter:auto when no ANTHROPIC_API_KEY). But the subagent
# LLM loop does NOT go through that chokepoint: it constructs an Anthropic SDK
# client DIRECTLY via a default factory —
#
#     const makeAnthropic = deps.makeAnthropic ?? (() => new Anthropic());
#
# On this deployment (NO ANTHROPIC_API_KEY provisioned) that `new Anthropic()`
# default would build a native client and reach the Anthropic API directly,
# bypassing FIX-NA-1. We pin models.tier.subagent=openrouter:auto so the native
# default is INERT in practice — but "inert by configuration" is a silent trap:
# a config drift re-arms the native path with zero warning.
#
# This patch is the MINIMAL safe hardening: it does NOT re-architect the subagent
# loop through the gateway (that is the upstream deprecate_when). It replaces the
# silent native fallback with a GUARD — when ANTHROPIC_API_KEY is unset, the
# default factory THROWS a tagged, greppable Error instead of constructing a
# native client. So a no-key deployment that ever reaches this path fails LOUD
# (named for review) rather than quietly calling the Anthropic API.
#
# Site patched: src/core/minions/handlers/subagent.ts
#   `const makeAnthropic = deps.makeAnthropic ?? (() => new Anthropic());`
#
# Applied at Docker BUILD; idempotent; FAILS THE BUILD LOUDLY (old container
# keeps serving) if the anchor moved — never a silent no-op. Python transform
# with fail-closed anchor assertions (container ships python3.12).
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

OLD = "  const makeAnthropic = deps.makeAnthropic ?? (() => new Anthropic());"
NEW = (
    "  // [VF-FIX-NA-2] This deployment provisions NO ANTHROPIC_API_KEY. The\n"
    "  // subagent loop builds its Anthropic client DIRECTLY here — it does NOT go\n"
    "  // through resolveRecipe (FIX-NA-1), so the `() => new Anthropic()` default\n"
    "  // would reach the Anthropic API directly, bypassing the no-native guarantee.\n"
    "  // Block the silent native fallback: when no key is set, THROW (loud, named\n"
    "  // for review) instead of constructing a native client. With a key present,\n"
    "  // or an explicit deps.makeAnthropic, behavior is unchanged. MINIMAL hardening\n"
    "  // — routing the subagent loop through the gateway is the upstream fix.\n"
    "  const makeAnthropic =\n"
    "    deps.makeAnthropic ??\n"
    "    (() => {\n"
    "      if (!process.env.ANTHROPIC_API_KEY) {\n"
    "        throw new Error(\n"
    "          \"ERR_NATIVE_ANTHROPIC_BLOCKED [VF-FIX-NA-2]: subagent loop must not \" +\n"
    "            \"construct a native Anthropic client without a key; configure \" +\n"
    "            \"models.tier.subagent=openrouter:auto\",\n"
    "        );\n"
    "      }\n"
    "      return new Anthropic();\n"
    "    });"
)

if OLD not in s:
    sys.stderr.write("[subagent-na2] ERROR: anchor missing (const makeAnthropic = deps.makeAnthropic ?? (() => new Anthropic());) in minions/handlers/subagent.ts — gbrain changed the native fallback site. RE-POINT THIS PATCH (UPGRADING_GBRAIN.md). FAILING THE BUILD.\n")
    sys.exit(1)

s = s.replace(OLD, NEW, 1)
open(path, 'w', encoding='utf-8').write(s)
print("[subagent-na2] applied minions/handlers/subagent.ts (1 site)")
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
echo "[subagent-na2] ✓ applied: subagent native-Anthropic fallback now throws [$SENTINEL] when no ANTHROPIC_API_KEY."
echo "[subagent-na2] done."
