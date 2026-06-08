#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-source-pages-mentions-only.sh   (FIX-TE-2)
#
# WHY THIS EXISTS
# `inferLinkType` (src/core/link-extraction.ts:683) applies tuned per-edge
# verb regexes (FOUNDED_RE / INVESTED_RE / ADVISES_RE / WORKS_AT_RE) and
# person-page role priors to EVERY non-media page. Source/podcast pages
# (type: source, type: media subtype podcast) are RAW CAPTURES — transcripts,
# article bodies, episode descriptions — full of investment/founder/advisor
# language that is ABOUT third parties, not a relationship the source page
# itself holds. Running verb inference on them mints false typed edges
# (e.g. a podcast transcript that says "Sequoia invested in Acme" produces a
# spurious `invested_in` edge FROM the podcast page). Those pages should emit
# `mentions` edges ONLY.
#
# The existing code already does exactly this for `type: media` at the TOP of
# inferLinkType (link-extraction.ts:684: `if (pageType === 'media') return
# 'mentions';`). This patch widens that early guard to also cover `source`
# pages (and is a structural twin to media — podcasts are type:media so they're
# already covered by the existing line, but `type: source` web/article/feed
# captures are NOT). One inserted guard, immediately after the media guard.
#
# ANCHOR: the existing media guard line
#   `  if (pageType === 'media') {` (link-extraction.ts:684).
# We insert a sibling `source` guard right after its closing brace.
#
# This is a gbrain *core* modification. Applied at Docker BUILD time after the
# gbrain install; baked in; re-applied on every GBRAIN_REF bump. Idempotent.
#
# NOTE on the larger sibling FIX-TE-1 (endpoint/directionality gate): that one
# is NOT this patch — it edits the BrainBench-calibrated verb heuristics and is
# spec'd for upstream (see proposed-patches/README.md + SPEC-FIX-TE-1). This
# patch is the narrow, low-risk source/podcast exclusion only.
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
  echo "[gbrain-patch:te-2] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi

FILE="$GBRAIN_SRC/core/link-extraction.ts"
if [ ! -f "$FILE" ]; then
  echo "[gbrain-patch:te-2] ERROR: $FILE not found." >&2
  exit 1
fi
echo "[gbrain-patch:te-2] target: $FILE"

# Anchor: the existing media early-return guard. Self-audit fails the build if
# the function shape changed (e.g. gbrain refactored inferLinkType).
ANCHOR="if (pageType === 'media') {"
if ! grep -qF "$ANCHOR" "$FILE"; then
  echo "[gbrain-patch:te-2] ERROR: media-guard anchor gone from inferLinkType — RE-POINT THIS PATCH (see UPGRADING_GBRAIN.md)." >&2
  exit 1
fi

if grep -qF 'FIX-TE-2' "$FILE"; then
  echo "[gbrain-patch:te-2] ✓ already applied (sentinel present); no-op."
  exit 0
fi

# The existing media guard is a 3-line block:
#   if (pageType === 'media') {
#     return 'mentions';
#   }
# We insert our source guard immediately AFTER that block's closing brace.
# Anchor the insert on the media guard's `return 'mentions';` line, which is
# unique within this block context, then add our guard after the next `}`.
# To keep this robust we instead match the full media block and append.
MEDIA_BLOCK="$(cat <<'EOF'
  if (pageType === 'media') {
    return 'mentions';
  }
EOF
)"

INSERT="$(cat <<'EOF'
  // FIX-TE-2 (hermes-template build patch): source/podcast captures are RAW
  // text ABOUT third parties — transcripts, article bodies, feed items — so
  // their entity refs must be `mentions`, never typed verbs. Running the
  // investment/founder/advisor regexes on a transcript that merely QUOTES
  // "Sequoia invested in Acme" would mint a spurious invested_in edge FROM the
  // source page. (Podcasts are type:media → already caught by the guard above;
  // this covers type:source web/article/feed captures the media guard misses.)
  if ((pageType as string) === 'source') {
    return 'mentions';
  }
EOF
)"

TMP="$(mktemp)"
# Use perl slurp to insert INSERT right after the media block.
MEDIA_BLOCK="$MEDIA_BLOCK" INSERT="$INSERT" perl -0777 -i -pe '
  my $b = $ENV{MEDIA_BLOCK};
  my $i = $ENV{INSERT};
  # Insert once, right after the media block. The $(cat <<EOF) capture strips
  # the trailing newline off both $b and $i, so we re-add a "\n" between the
  # block-closing "}" and our guard, and another after it, to keep tidy lines.
  s/\Q$b\E/$b\n$i\n/ unless /FIX-TE-2/;
' "$FILE"

if [ "$(grep -cF 'FIX-TE-2' "$FILE")" = "0" ]; then
  echo "[gbrain-patch:te-2] ERROR: insert did not land — the media block shape may differ. RE-POINT." >&2
  exit 1
fi
echo "[gbrain-patch:te-2] ✓ type:source pages now infer 'mentions' only (podcasts already covered by the media guard)."
echo "[gbrain-patch:te-2] done."
