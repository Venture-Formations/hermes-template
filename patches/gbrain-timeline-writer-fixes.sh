#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-timeline-writer-fixes.sh   (FIX-TL-1 + TL-2 + TL-4)
#
# WHY THIS EXISTS
# Three related bugs turn the on-disk `## Timeline` section on every enriched
# entity page into crawl-dated noise rather than a meaningful chronology.
# All three touch the WRITER side of the timeline pipeline (the reader/parser
# side is handled by the companion patch gbrain-timeline-bullet-hyphen-split,
# FIX-TL-3, which must ship first).
#
# ── FIX-TL-1 ─── Wrong date source in enrichment-service (enrichment-service.ts:116)
#
#   `enrichEntity` stamps every DB timeline entry with `new Date()` (wall-clock
#   NOW) rather than the source page's actual publish date. Beyond producing
#   wrong ordering, `now()` defeats the idempotency of the
#   `idx_timeline_dedup` UNIQUE index on `(page_id, date, summary, source)`:
#   two runs of the same source on different calendar days produce two distinct
#   `date` values → two rows. This fix resolves the date from the source page's
#   frontmatter using the precedence chain our collectors stamp:
#     published_at (ISO, yt/source-sync) → captured_at (ISO, capture skill)
#     → today as last resort.
#
# ── FIX-TL-2 ─── "Referenced in" rows flood `## Timeline` (backlinks.ts:66-67 + 164-178)
#
#   `check-backlinks fix` appends a dated `- **DATE** | Referenced in [X](path)`
#   line into the target's `## Timeline` section for EVERY bare back-edge.
#   Every entity mention becomes a dated timeline event; ~90% of rows in the
#   live brain are this noise. Fix: route bare back-edge entries to a
#   `## Mentions` section (new, undated list) and stop touching `## Timeline`
#   for backlink-only references. Real dated events (from `engine.addTimelineEntry`)
#   stay in the DB timeline; `## Timeline` on disk is reserved for enriched
#   genuine events.
#
# ── FIX-TL-4 ─── `## Timeline` rendered unsorted (backlinks.ts:164-178)
#
#   When `fixBacklinkGaps` formerly inserted into `## Timeline`, it did so with
#   no sort — accumulating entries in insert order, not reverse-chronological
#   as the enrich template promises (`skills/enrich/SKILL.md` "Reverse
#   chronological"). With TL-2 blocking new writes to `## Timeline`, TL-4 adds
#   a cleanup sort pass: whenever `fixBacklinkGaps` writes a page, it also
#   re-sorts any existing `## Timeline` section by date DESC so legacy
#   unsorted entries are cleaned up in place.
#
# ── ANCHOR STRATEGY ────────────────────────────────────────────────────────
# Three guarded edit blocks across two files; each has its own idempotency
# sentinel (`FIX-TL-1-WRITER`, `FIX-TL-2-WRITER`, `FIX-TL-4-WRITER`). A
# self-audit anchor for each block ensures the build FAILS if the upstream
# code moves rather than silently no-oping.
#
# ── ORDERING / DEPENDENCIES ────────────────────────────────────────────────
# Precondition: FIX-TL-3 (gbrain-timeline-bullet-hyphen-split.sh) must be
# applied first — the parser must be hyphen-safe before we change what the
# writer emits.
#
# This is a gbrain *core* modification. Applied at Docker BUILD time after
# the gbrain install; idempotent; re-applied on every GBRAIN_REF bump.
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Locate the gbrain source tree
# ---------------------------------------------------------------------------
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then
  echo "[gbrain-patch:tl-writer] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
echo "[gbrain-patch:tl-writer] target: $GBRAIN_SRC"

ENRICH_FILE="$GBRAIN_SRC/core/enrichment-service.ts"
BACKLINKS_FILE="$GBRAIN_SRC/commands/backlinks.ts"

for f in "$ENRICH_FILE" "$BACKLINKS_FILE"; do
  if [ ! -f "$f" ]; then
    echo "[gbrain-patch:tl-writer] ERROR: $f not found." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 2. FIX-TL-1 — Resolve timeline date from source page frontmatter
#    File: src/core/enrichment-service.ts (~line 116)
#
#    Anchor: the `date: new Date().toISOString().split('T')[0] ?? '',` line
#    inside the addTimelineEntry call, inside enrichEntity.
#
#    This is the UNIQUE line across the whole file (confirmed via grep:
#    there is exactly one `date: new Date().toISOString().split` call in
#    enrichment-service.ts). The perl replacement targets the two-line
#    block starting at the addTimelineEntry call so the context is tight.
# ---------------------------------------------------------------------------
echo "[gbrain-patch:tl-writer] [TL-1] patching enrichment-service.ts..."

# Anchor: the `date: new Date()...` line (unique in the file) confirms the
# addTimelineEntry block is present in its expected form.
TL1_ANCHOR="      date: new Date().toISOString().split('T')[0] ?? '',"

if grep -qF 'FIX-TL-1-WRITER' "$ENRICH_FILE"; then
  echo "[gbrain-patch:tl-writer] [TL-1] ✓ already applied (FIX-TL-1-WRITER sentinel present); no-op."
else
  if ! grep -qF "$TL1_ANCHOR" "$ENRICH_FILE"; then
    echo "[gbrain-patch:tl-writer] ERROR: TL-1 anchor ('date: new Date().toISOString().split...' inside addTimelineEntry) gone from enrichment-service.ts — gbrain moved it. RE-POINT THIS PATCH (see UPGRADING_GBRAIN.md)." >&2
    exit 1
  fi

  # Replace the TWO-LINE block (`await engine.addTimelineEntry(slug, {` +
  # `date: new Date()...`) with:
  #   1. preamble: resolve date from source page frontmatter
  #   2. the original await call (unchanged)
  #   3. `date: _tlDate,` (replaces the now() expression)
  #
  # Matching the two-line block (unique in the file) keeps the preamble
  # BEFORE the object literal opening brace so the `const` declarations land
  # in statement position (not inside the `addTimelineEntry({...})` call).
  #
  # Resolved precedence: published_at → captured_at → today.
  # These are the keys our collectors stamp (yt/source-sync stamps
  # `published_at`; the capture skill stamps `captured_at`).
  # Both may be ISO strings OR Date objects depending on YAML parser quirks,
  # so we handle both via the inline IIFE.
  #
  # `_srcPageForDate` / `_tlDate` use underscore prefix to avoid clashing
  # with any locals in the surrounding enrichEntity function scope.

  # The two-line OLD block: await call opening + date: now() line.
  # Verified unique (grep count = 1) in enrichment-service.ts@gbrain@099d9a8.
  OLD_BLOCK2="    await engine.addTimelineEntry(slug, { // gbrain-allow-direct-insert: auto-timeline reconciliation triggered by entity reference in source markdown
      date: new Date().toISOString().split('T')[0] ?? '',"

  NEW_BLOCK2="    // FIX-TL-1-WRITER: resolve date from source page frontmatter
    // (published_at → captured_at → today) so timeline entries are idempotent
    // across re-runs and correctly dated regardless of crawl time.
    const _srcPageForDate = await engine.getPage(request.sourceSlug).catch(() => null);
    const _fmRaw = _srcPageForDate?.frontmatter?.published_at
      ?? _srcPageForDate?.frontmatter?.captured_at ?? null;
    const _tlDate: string = (() => {
      if (!_fmRaw) return new Date().toISOString().slice(0, 10);
      if (_fmRaw instanceof Date) return _fmRaw.toISOString().slice(0, 10);
      const s = String(_fmRaw).trim();
      return /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : new Date().toISOString().slice(0, 10);
    })();
    await engine.addTimelineEntry(slug, { // gbrain-allow-direct-insert: auto-timeline reconciliation triggered by entity reference in source markdown
      date: _tlDate,"

  export OLD_BLOCK2 NEW_BLOCK2
  perl -0777 -i -pe '
    my $o = $ENV{OLD_BLOCK2};
    my $n = $ENV{NEW_BLOCK2};
    s/\Q$o\E/$n/ unless /FIX-TL-1-WRITER/;
  ' "$ENRICH_FILE"

  if ! grep -qF 'FIX-TL-1-WRITER' "$ENRICH_FILE"; then
    echo "[gbrain-patch:tl-writer] ERROR: TL-1 insert did not land in enrichment-service.ts. RE-POINT." >&2
    exit 1
  fi
  echo "[gbrain-patch:tl-writer] [TL-1] ✓ timeline date now resolved from source page frontmatter (published_at → captured_at → today)."
fi

# ---------------------------------------------------------------------------
# 3. FIX-TL-2a — buildBacklinkEntry: emit undated Mentions line
#    File: src/commands/backlinks.ts (~line 67)
#
#    Anchor: the function body return line (unique in the file):
#      return `- **${date}** | Referenced in [${sourceTitle}](${sourcePath})`;
# ---------------------------------------------------------------------------
echo "[gbrain-patch:tl-writer] [TL-2a] patching backlinks.ts buildBacklinkEntry..."

TL2A_ANCHOR="  return \`- **\${date}** | Referenced in [\${sourceTitle}](\${sourcePath})\`;"

if grep -qF 'FIX-TL-2-WRITER' "$BACKLINKS_FILE"; then
  echo "[gbrain-patch:tl-writer] [TL-2a] ✓ already applied (FIX-TL-2-WRITER sentinel present); no-op."
else
  if ! grep -qF "$TL2A_ANCHOR" "$BACKLINKS_FILE"; then
    echo "[gbrain-patch:tl-writer] ERROR: TL-2a anchor (buildBacklinkEntry return line) gone from backlinks.ts — gbrain moved it. RE-POINT THIS PATCH." >&2
    exit 1
  fi

  OLD_RETURN="  return \`- **\${date}** | Referenced in [\${sourceTitle}](\${sourcePath})\`;"
  NEW_RETURN="  // FIX-TL-2-WRITER: bare back-edges go to ## Mentions (undated list), not ## Timeline.
  // The \`date\` parameter is kept for API compatibility but is no longer emitted;
  // real dated events live exclusively in the DB timeline (engine.addTimelineEntry).
  return \`- Referenced in [\${sourceTitle}](\${sourcePath})\`;"

  export OLD_RETURN NEW_RETURN
  perl -0777 -i -pe '
    my $o = $ENV{OLD_RETURN};
    my $n = $ENV{NEW_RETURN};
    s/\Q$o\E/$n/ unless /FIX-TL-2-WRITER/;
  ' "$BACKLINKS_FILE"

  if ! grep -qF 'FIX-TL-2-WRITER' "$BACKLINKS_FILE"; then
    echo "[gbrain-patch:tl-writer] ERROR: TL-2a insert did not land in backlinks.ts buildBacklinkEntry. RE-POINT." >&2
    exit 1
  fi
  echo "[gbrain-patch:tl-writer] [TL-2a] ✓ buildBacklinkEntry now emits undated Mentions line."
fi

# ---------------------------------------------------------------------------
# 4. FIX-TL-2b + FIX-TL-4 — fixBacklinkGaps: route to ## Mentions + sort ## Timeline
#    File: src/commands/backlinks.ts (~lines 164-178)
#
#    Anchor: `      // Insert into Timeline section` (unique in the file).
#    We use perl to replace from this comment through the closing `}` of the
#    else branch. The regex uses \n to match across lines (slurp mode -0777).
# ---------------------------------------------------------------------------
echo "[gbrain-patch:tl-writer] [TL-2b/TL-4] patching backlinks.ts fixBacklinkGaps..."

TL4_ANCHOR="      // Insert into Timeline section"

if grep -qF 'FIX-TL-4-WRITER' "$BACKLINKS_FILE"; then
  echo "[gbrain-patch:tl-writer] [TL-2b/TL-4] ✓ already applied (FIX-TL-4-WRITER sentinel present); no-op."
else
  if ! grep -qF "$TL4_ANCHOR" "$BACKLINKS_FILE"; then
    echo "[gbrain-patch:tl-writer] ERROR: TL-2b/TL-4 anchor ('// Insert into Timeline section') gone from backlinks.ts fixBacklinkGaps. RE-POINT THIS PATCH." >&2
    exit 1
  fi

  # Replacement block (exported as env var for perl -0777 to receive cleanly).
  # This replaces the original Timeline-insert block with:
  #   (a) TL-2b: Mentions-section routing (no dated Timeline writes)
  #   (b) TL-4:  a sort pass on any existing ## Timeline block
  #
  # The NEW_BLOCK ends WITHOUT a trailing newline so the perl substitution
  # stays byte-for-byte aligned with what was there before.  `fixed++` is
  # left in place by the outer for-loop.

  # We match from the anchor comment through the closing `}` of the else branch.
  # The regex: from `      // Insert into Timeline section` through the closing
  # `      }` (6-space indent) which ends the if/else block.  Because the file
  # uses consistent 6-space indentation for this level, `      }` followed by
  # a newline and `      fixed++` is the precise terminator.
  #
  # perl regex (slurp):  s/\Q<anchor>\E.*?(?=\n      fixed\+\+)/<new_block>/s

  export TL4_ANCHOR
  # NEW_BLOCK via quoted heredoc — NO '\'' escaping (that mangled the empty-string
  # literal and produced an unterminated string). Inside <<'TLEOF' nothing is
  # expanded, so the TS single-quotes and \n escapes are taken verbatim.
  read -r -d '' NEW_BLOCK <<'TLEOF' || true
      // FIX-TL-2b-WRITER: route bare back-edge entries to ## Mentions (undated list).
      // Real dated events live in the DB timeline (engine.addTimelineEntry) only.
      // FIX-TL-4-WRITER: also re-sort any existing ## Timeline block by date DESC.
      if (content.includes('## Mentions')) {
        // Append inside existing ## Mentions section (before next ## heading)
        const mParts = content.split('## Mentions');
        const mAfter = mParts[1];
        const mNext = mAfter.match(/\n## /);
        if (mNext) {
          const mIdx = mParts[0].length + '## Mentions'.length + mNext.index!;
          content = content.slice(0, mIdx) + '\n' + entry + content.slice(mIdx);
        } else {
          content = content.trimEnd() + '\n' + entry + '\n';
        }
      } else {
        // Create ## Mentions section at end of page
        content = content.trimEnd() + '\n\n## Mentions\n\n' + entry + '\n';
      }

      // FIX-TL-4-WRITER: re-sort existing ## Timeline section by date DESC
      // (cleans up legacy unsorted backlink noise on pages we touch).
      const _TL_LINE_RE = /^\s*-?\s*\*\*(\d{4}-\d{2}-\d{2})\*\*[\s|\-—–]/;
      if (content.includes('## Timeline')) {
        const tlParts = content.split('## Timeline');
        const tlAfterRaw = tlParts[1];
        const tlNextMatch = tlAfterRaw.match(/\n## /);
        const tlBodyEnd = tlNextMatch ? tlNextMatch.index! : tlAfterRaw.length;
        const tlBody = tlAfterRaw.slice(0, tlBodyEnd);
        const tlRest = tlAfterRaw.slice(tlBodyEnd);
        const tlLines = tlBody.split('\n');
        const groups: { date: string; raw: string[] }[] = [];
        const pre: string[] = [];
        let cur: { date: string; raw: string[] } | null = null;
        for (const ln of tlLines) {
          const m = _TL_LINE_RE.exec(ln);
          if (m) {
            if (cur) groups.push(cur);
            cur = { date: m[1], raw: [ln] };
          } else if (cur) {
            cur.raw.push(ln);
          } else {
            pre.push(ln);
          }
        }
        if (cur) groups.push(cur);
        groups.sort((a, b) => b.date.localeCompare(a.date));
        const sorted = pre.join('\n')
          + (groups.length ? '\n' : '')
          + groups.map(g => g.raw.join('\n')).join('\n');
        content = tlParts[0] + '## Timeline' + sorted + tlRest;
      }
TLEOF
  export NEW_BLOCK

  perl -0777 -i -pe '
    my $anchor = quotemeta($ENV{TL4_ANCHOR});
    my $new    = $ENV{NEW_BLOCK};
    # Match from anchor through the line just before `      fixed++`
    s/${anchor}.*?(?=\n      fixed\+\+)/$new/s unless /FIX-TL-4-WRITER/;
  ' "$BACKLINKS_FILE"

  if ! grep -qF 'FIX-TL-4-WRITER' "$BACKLINKS_FILE"; then
    echo "[gbrain-patch:tl-writer] ERROR: TL-2b/TL-4 insert did not land in backlinks.ts fixBacklinkGaps. RE-POINT." >&2
    exit 1
  fi
  echo "[gbrain-patch:tl-writer] [TL-2b/TL-4] ✓ fixBacklinkGaps now routes to ## Mentions and re-sorts ## Timeline."
fi

# ---------------------------------------------------------------------------
# 5. Post-patch verification
# ---------------------------------------------------------------------------
echo "[gbrain-patch:tl-writer] post-patch verification..."

FAIL=0

if ! grep -qF 'FIX-TL-1-WRITER' "$ENRICH_FILE"; then
  echo "[gbrain-patch:tl-writer] ERROR: FIX-TL-1-WRITER sentinel missing from enrichment-service.ts" >&2
  FAIL=1
fi
if ! grep -qF 'FIX-TL-2-WRITER' "$BACKLINKS_FILE"; then
  echo "[gbrain-patch:tl-writer] ERROR: FIX-TL-2-WRITER sentinel missing from backlinks.ts" >&2
  FAIL=1
fi
if ! grep -qF 'FIX-TL-4-WRITER' "$BACKLINKS_FILE"; then
  echo "[gbrain-patch:tl-writer] ERROR: FIX-TL-4-WRITER sentinel missing from backlinks.ts" >&2
  FAIL=1
fi

# The old now()-date line must be gone
if grep -qF "date: new Date().toISOString().split('T')[0] ?? ''," "$ENRICH_FILE"; then
  echo "[gbrain-patch:tl-writer] ERROR: old now()-date line still present in enrichment-service.ts" >&2
  FAIL=1
fi
# The old Timeline-insert comment must be gone
if grep -qF '// Insert into Timeline section' "$BACKLINKS_FILE"; then
  echo "[gbrain-patch:tl-writer] ERROR: old '// Insert into Timeline section' still present in backlinks.ts" >&2
  FAIL=1
fi
# The old dated return line must be gone from buildBacklinkEntry
if grep -qF '**${date}** | Referenced in' "$BACKLINKS_FILE"; then
  echo "[gbrain-patch:tl-writer] ERROR: old dated 'Referenced in' return still present in backlinks.ts buildBacklinkEntry" >&2
  FAIL=1
fi

if [ "$FAIL" = "1" ]; then
  echo "[gbrain-patch:tl-writer] ERROR: post-patch verification failed — see errors above." >&2
  exit 1
fi

echo "[gbrain-patch:tl-writer] ✓ all sentinels present; old code removed."
echo "[gbrain-patch:tl-writer] done."
