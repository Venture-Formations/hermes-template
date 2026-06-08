#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-enrich-skill-fidelity.sh   (FIX-EN-1 + FIX-EN-2)
#
# WHY THIS EXISTS
# The LIVE entity-page producer on this deployment is the *agent* `enrich`
# skill (cron `gbrain-enrichment-weekly`), NOT the CLI `gbrain enrich`. Its
# whole stance/contradiction handling is two UNENFORCED prose lines:
#   - skills/enrich/SKILL.md:60  "When sources conflict, note the contradiction"
#   - skills/enrich/SKILL.md:179 "Flag contradictions between new signal and ..."
# and its signal-extraction table (SKILL.md:104-112) maps signals to
# TOPIC-LABELED sections ("State section (hard facts)") with no instruction
# to preserve the quantified/contrarian claim ITSELF. The measured result is
# ~19% essence retention and a class of inversions (Google/Micron/"40%" stats
# flipped or neutralized). This patch INSERTS two enforced rules:
#   FIX-EN-1: preserve the single sharpest FALSIFIABLE claim per source
#             VERBATIM, with its exact number/percentage + speaker + citation.
#   FIX-EN-2: a mandatory stance/contradiction reconciliation step that keeps
#             BOTH sides of an inverted claim under a `## Contradictions /
#             Open Disputes` heading instead of silently overwriting/averaging.
#
# `skills/enrich/SKILL.md` is a GBRAIN-ORIGINAL skill (scaffolded from
# garrytan/gbrain), so it CANNOT be hand-edited in hermes-workspace without
# creating `gbrain skillpack reference` merge conflicts. The durable paths are
# (a) this build-time patch, or (b) an upstream PR to garrytan/gbrain. This
# file is path (a): applied at Docker BUILD time right after the gbrain
# install, baked into the image, re-applied on every GBRAIN_REF bump.
#
# ANCHOR: the `## Output Format` heading (skills/enrich/SKILL.md:319). We
# INSERT a block immediately before it rather than rewriting any existing
# section, so the self-audit anchor survives upstream edits to the body.
#
# Idempotent: a sentinel marker (FIX-EN-1/2 BEGIN) is checked first; a second
# run is a no-op.
# ---------------------------------------------------------------------------
set -euo pipefail

# Resolve the gbrain install tree across build + runtime layouts.
GBRAIN_ROOT=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain" \
  "/usr/local/bun/install/global/node_modules/gbrain" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain"; do
  if [ -d "$d" ]; then GBRAIN_ROOT="$d"; break; fi
done
if [ -z "$GBRAIN_ROOT" ]; then
  echo "[gbrain-patch:en-fidelity] ERROR: gbrain tree not found; nothing patched." >&2
  exit 1
fi

SKILL="$GBRAIN_ROOT/skills/enrich/SKILL.md"
if [ ! -f "$SKILL" ]; then
  echo "[gbrain-patch:en-fidelity] ERROR: $SKILL not found." >&2
  exit 1
fi
echo "[gbrain-patch:en-fidelity] target: $SKILL"

# Self-audit the anchor BEFORE touching the file. If gbrain renames/removes
# the `## Output Format` heading, FAIL THE BUILD (the old container keeps
# serving — no outage) so the patch is re-pointed rather than silently lost.
ANCHOR='## Output Format'
if ! grep -qF "$ANCHOR" "$SKILL"; then
  echo "[gbrain-patch:en-fidelity] ERROR: anchor '$ANCHOR' gone from enrich SKILL.md — RE-POINT THIS PATCH (see UPGRADING_GBRAIN.md)." >&2
  exit 1
fi

# Idempotency guard.
if grep -qF 'FIX-EN-1/2 BEGIN' "$SKILL"; then
  echo "[gbrain-patch:en-fidelity] ✓ already applied (sentinel present); no-op."
  exit 0
fi

# The inserted block. Written to a temp file (INSERT_FILE) so we can splice it
# in ahead of the anchor line with awk reading the file directly — no awk -v
# multiline-variable quoting hazards (the block contains apostrophes, e.g.
# "They're", which would otherwise collide with the awk single-quoted program).
INSERT_FILE="$(mktemp)"
cat > "$INSERT_FILE" <<'BLOCK'
<!-- FIX-EN-1/2 BEGIN (hermes-template build patch — verbatim claim + stance reconciliation) -->

## Fidelity Rules (MANDATORY — applies to every State / belief / build section)

**FIX-EN-1 — Preserve the sharpest falsifiable claim VERBATIM.**
For EACH source you compile from, identify the single sharpest *falsifiable*
claim it makes about the entity and preserve it **verbatim**, including:
- its exact **number / percentage / magnitude** (never round, neutralize, or drop it), and
- the **speaker / author** who made the claim, and
- an inline `[Source: …]` citation.

Never paraphrase a quantified or contrarian claim into a neutral topic label.
"Micron guided gross margin **down ~40%** QoQ (CFO, Q3 call) [Source: …]"
is correct; "discussed margin trends" is a fidelity FAILURE. The State,
What They Believe, and What They're Building sections must read as
claim + number + speaker, NOT as a fact-list of topics.

**FIX-EN-2 — Reconcile stance before writing (no silent overwrite).**
Before writing the State section, compare each new claim against (a) the
existing `compiled_truth` on the page and (b) the other retrieved sources.
If a claim **inverts or contradicts** an existing one (opposite sign, a
different number, a reversed stance), you MUST keep **BOTH**, each with its
own `[Source: …]` citation, under a dedicated heading:

```
## Contradictions / Open Disputes
- **<claim A, verbatim, with number+speaker>** [Source: …]
  vs **<claim B, verbatim, with number+speaker>** [Source: …]
  — <one line: which is more recent / more authoritative, or "unresolved">
```

Emit `## Contradictions / Open Disputes` **only when** at least one such
conflict exists (omit-if-empty; no placeholder sentinel). NEVER average two
conflicting numbers, and NEVER silently overwrite the older claim — the
disagreement is itself the intelligence.

<!-- FIX-EN-1/2 END -->

BLOCK

TMP="$(mktemp)"
# Splice the insert file immediately before the FIRST line equal to the anchor
# heading. awk reads INSERT_FILE via getline so the block's apostrophes never
# touch the single-quoted awk program.
awk -v insfile="$INSERT_FILE" '
  !done && $0 == "## Output Format" {
    while ((getline line < insfile) > 0) print line
    close(insfile)
    done = 1
  }
  { print }
' "$SKILL" > "$TMP"

# Post-condition: both sentinels present exactly once.
if [ "$(grep -cF 'FIX-EN-1/2 BEGIN' "$TMP")" != "1" ] || [ "$(grep -cF 'FIX-EN-1/2 END' "$TMP")" != "1" ]; then
  echo "[gbrain-patch:en-fidelity] ERROR: splice produced wrong sentinel count — aborting, file unchanged." >&2
  rm -f "$TMP" "$INSERT_FILE"
  exit 1
fi

mv "$TMP" "$SKILL"
rm -f "$INSERT_FILE"
echo "[gbrain-patch:en-fidelity] ✓ inserted FIX-EN-1/2 fidelity block before '## Output Format'."
echo "[gbrain-patch:en-fidelity] done."
