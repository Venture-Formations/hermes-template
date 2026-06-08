#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-timeline-bullet-hyphen-split.sh   (FIX-TL-3)
#
# WHY THIS EXISTS
# `extractTimelineFromContent` parses on-disk `## Timeline` bullets into
# structured (date, source, summary) rows. Its "Format 1" bullet regex at
# src/commands/extract.ts:475 is:
#
#   /^-\s+\*\*(\d{4}-\d{2}-\d{2})\*\*\s*\|\s*(.+?)\s*[—–-]\s*(.+)$/gm
#                                              ^^^^^         ^^^^^^^
#                                          non-greedy    splits on bare hyphen
#
# The separator class `[—–-]` includes a BARE ASCII hyphen, and group 2 is
# NON-GREEDY, so the regex splits a bullet on the FIRST hyphen it sees — even
# one *inside* a slug or word. A back-link bullet like
#
#   - **2026-06-01** | Referenced in [Hermes Agent](.../7JRHSo2F-Wk.md)
#
# is mangled to source='Referenced in [Hermes Agent…7JRHSo2F',
# summary='Wk.md)' — the YouTube id `7JRHSo2F-Wk` is split on its hyphen.
# (Observed in the 2026-06-01T01:08 extract batch, audit 01-company-
# legibility-audit.md:57: rows 6052, 6057-6060.) Re-runs that happen to
# re-emit the clean line then created CORRUPT+CLEAN duplicate rows.
#
# THE FIX: require the source/summary separator to be a true em/en dash with
# surrounding spaces ( — / – ), never a bare ASCII hyphen. A summary-only
# bullet (`| text` with no separator) keeps its whole text as the summary.
# This is the deterministic, BrainBench-irrelevant parser hygiene fix — one
# regex, one anchor, lowest-risk patch in the audit.
#
# This is a gbrain *core* modification (single source line in extract.ts).
# Applied at Docker BUILD time after the gbrain install; baked in; re-applied
# on every GBRAIN_REF bump. Safe to run on a live container.
#
# Idempotent: the fixed regex is detected first; a second run is a no-op.
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
  echo "[gbrain-patch:tl-3] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

FILE="$GBRAIN_SRC/commands/extract.ts"
if [ ! -f "$FILE" ]; then
  echo "[gbrain-patch:tl-3] ERROR: $FILE not found." >&2
  exit 1
fi
echo "[gbrain-patch:tl-3] target: $FILE"

# The buggy regex literal (the self-audit anchor). The bare-hyphen separator
# class `[—–-]` after the non-greedy `(.+?)` is the defect.
OLD='const bulletPattern = /^-\s+\*\*(\d{4}-\d{2}-\d{2})\*\*\s*\|\s*(.+?)\s*[—–-]\s*(.+)$/gm;'

# The fixed regex. Two changes:
#   1. The source/summary separator must be a spaced em/en dash ` — ` / ` – `
#      (or an explicit double-hyphen ` -- `), NEVER a bare single hyphen, so a
#      hyphen inside a slug/word can't trigger a split.
#   2. The separator+source group is OPTIONAL — a `| summary-only` bullet
#      with no dash keeps its full text as the summary (group 3), with
#      source defaulting to 'markdown' (handled in the awk-inserted line below).
# We rewrite group order so the kept text is always the summary; when a real
# `source — summary` form is present, group 2 is the source.
NEW='const bulletPattern = /^-\s+\*\*(\d{4}-\d{2}-\d{2})\*\*\s*\|\s*(?:(.+?)\s+(?:—|–|--)\s+)?(.+)$/gm;'

# Self-audit: the buggy literal MUST be present (unless already fixed).
if grep -qF "$NEW" "$FILE"; then
  echo "[gbrain-patch:tl-3] ✓ already applied (fixed regex present); no-op."
  exit 0
fi
if ! grep -qF "$OLD" "$FILE"; then
  echo "[gbrain-patch:tl-3] ERROR: buggy bulletPattern anchor gone from extract.ts — gbrain changed the parser. RE-POINT THIS PATCH (see UPGRADING_GBRAIN.md)." >&2
  exit 1
fi

# `@` delimiter (never appears in the literals). Both sides are treated as
# fixed strings via a here-doc fed to a python-free literal replace: use perl
# in slurp mode with \Q..\E so regex metachars in OLD/NEW are inert.
OLD="$OLD" NEW="$NEW" perl -0777 -i -pe '
  my $o = $ENV{OLD}; my $n = $ENV{NEW};
  s/\Q$o\E/$n/g;
' "$FILE"

# The fixed regex makes group 2 (source) optional → it can be undefined.
# The push site at extract.ts:478 does `source: match[2].trim()`, which would
# throw on undefined. Patch that one call site to default to 'markdown'.
PUSH_OLD='entries.push({ slug, date: match[1], source: match[2].trim(), summary: match[3].trim() });'
PUSH_NEW='entries.push({ slug, date: match[1], source: (match[2] ? match[2].trim() : '"'"'markdown'"'"'), summary: match[3].trim() });'
if grep -qF "$PUSH_OLD" "$FILE"; then
  PUSH_OLD="$PUSH_OLD" PUSH_NEW="$PUSH_NEW" perl -0777 -i -pe '
    my $o = $ENV{PUSH_OLD}; my $n = $ENV{PUSH_NEW};
    s/\Q$o\E/$n/g;
  ' "$FILE"
  echo "[gbrain-patch:tl-3]   patched push site to default source to 'markdown'."
elif ! grep -qF "match[2] ? match[2].trim()" "$FILE"; then
  echo "[gbrain-patch:tl-3] ERROR: bullet push site (source: match[2].trim()) not found and not already patched — RE-POINT." >&2
  exit 1
fi

# Post-condition: the fixed regex is present, the buggy one is gone.
if ! grep -qF "$NEW" "$FILE" || grep -qF "$OLD" "$FILE"; then
  echo "[gbrain-patch:tl-3] ERROR: post-patch verification failed." >&2
  exit 1
fi
echo "[gbrain-patch:tl-3] ✓ timeline bullet separator now requires a spaced em/en dash; bare hyphens no longer split slugs."
echo "[gbrain-patch:tl-3] done."
