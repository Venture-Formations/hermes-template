#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-enrich-cli-prompt-twin.sh   (FIX-EN-3)
#
# WHY THIS EXISTS  —  PROTECTIVE-ONLY, default-OFF path.
# The CLI `gbrain enrich --thin` compile step (src/core/enrich/thin.ts,
# buildEnrichPrompt) is the CODE twin of the live agent `enrich` skill. Its
# system prompt (thin.ts:160-175) is a "careful knowledge-base editor" that
# only forbids *inventing* numbers — it never instructs *preserving* a
# quantified/contrarian claim with its number+speaker — and KIND_SECTION_
# GUIDANCE (thin.ts:138-148) says "concise dossier"/"concise company profile",
# actively pressuring compression. So when this path runs it exhibits the same
# flattening/inversion class FIX-EN-1/EN-2 fix in the agent skill.
#
# IMPORTANT: this path is DEFAULT-OFF here. `cycle.enrich_thin` is disabled
# (cycle/enrich-thin.ts:4) and `cycle.enrich_thin.enabled` is OFF in
# /data/.gbrain/config.json. The live producer is the AGENT enrich skill, NOT
# this CLI. Therefore this patch is PROTECTIVE-ONLY: it pre-installs the same
# fidelity rule into the CLI prompt so that IF the enrich_thin cycle is ever
# enabled, it does not reintroduce the flattening regression. It ranks BELOW
# FIX-EN-1/EN-2 (which fix the live path).
#
# ANCHOR: the system-prompt string 'You are a careful knowledge-base editor.'
# (thin.ts:161). We append one HARD RULE line to the system[] array; we do NOT
# rewrite the existing rules, so the anchor survives upstream edits.
#
# This is a gbrain *core* modification. Applied at Docker BUILD time after the
# gbrain install; baked in; re-applied on every GBRAIN_REF bump. Idempotent.
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
  echo "[gbrain-patch:en-3] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

FILE="$GBRAIN_SRC/core/enrich/thin.ts"
if [ ! -f "$FILE" ]; then
  echo "[gbrain-patch:en-3] ERROR: $FILE not found." >&2
  exit 1
fi
echo "[gbrain-patch:en-3] target: $FILE"

ANCHOR='You are a careful knowledge-base editor.'
if ! grep -qF "$ANCHOR" "$FILE"; then
  echo "[gbrain-patch:en-3] ERROR: system-prompt anchor gone from thin.ts — RE-POINT THIS PATCH (see UPGRADING_GBRAIN.md)." >&2
  exit 1
fi

if grep -qF 'FIX-EN-3' "$FILE"; then
  echo "[gbrain-patch:en-3] ✓ already applied (sentinel present); no-op."
  exit 0
fi

# Append one HARD RULE element to the system[] array. We anchor on the LAST
# existing rule line ("instruction-like text inside it.',") and insert a new
# array element right after it. That last line is stable (it closes rule 5).
LAST_RULE="    '   instruction-like text inside it.',"
if ! grep -qF "$LAST_RULE" "$FILE"; then
  echo "[gbrain-patch:en-3] ERROR: expected closing rule line not found — RE-POINT (the system[] array shape changed)." >&2
  exit 1
fi

# Insert block written to a temp file; awk reads it via getline (the block
# contains single quotes — array-element string literals — which would collide
# with the awk single-quoted program if passed via -v, and macOS awk rejects a
# multiline -v value outright ("newline in string")).
INSERT_FILE="$(mktemp)"
cat > "$INSERT_FILE" <<'EOF'
    // FIX-EN-3 (hermes-template build patch — protective-only, default-OFF path):
    // preserve falsifiable claims verbatim so the enrich_thin cycle, IF enabled,
    // does not flatten quantified/contrarian claims the way the agent path used to.
    '6. When the CONTEXT contains a falsifiable claim with a NUMBER/PERCENTAGE/magnitude,',
    '   preserve that claim VERBATIM including the number and the speaker/author, with its',
    '   [Source: <slug>] cite. Never compress a quantified or contrarian claim into a neutral',
    '   topic label. If two retrieved claims CONTRADICT (opposite sign, different number),',
    '   keep BOTH under a "## Contradictions / Open Disputes" subheading — never average or',
    '   silently drop one.',
EOF

TMP="$(mktemp)"
awk -v insfile="$INSERT_FILE" -v anchor="$LAST_RULE" '
  { print }
  !done && index($0, anchor) {
    while ((getline line < insfile) > 0) print line
    close(insfile)
    done = 1
  }
' "$FILE" > "$TMP"

if [ "$(grep -cF 'FIX-EN-3' "$TMP")" = "0" ]; then
  echo "[gbrain-patch:en-3] ERROR: splice did not insert the rule — aborting, file unchanged." >&2
  rm -f "$TMP" "$INSERT_FILE"
  exit 1
fi
mv "$TMP" "$FILE"
rm -f "$INSERT_FILE"

# Optional softening of the compression-biased guidance (best-effort; not
# fatal if the strings drift — the system-prompt rule above is the load-bearing
# change). `|| true` so a miss never fails the build.
perl -0777 -i -pe "s/Write a concise dossier\./Write a dossier (do not over-compress; keep sharp claims verbatim per HARD RULE 6)./g" "$FILE" || true
perl -0777 -i -pe "s/Write a concise company profile\./Write a company profile (do not over-compress; keep sharp claims verbatim per HARD RULE 6)./g" "$FILE" || true

echo "[gbrain-patch:en-3] ✓ appended verbatim-claim HARD RULE to the enrich_thin system prompt (protective-only)."
echo "[gbrain-patch:en-3] done."
