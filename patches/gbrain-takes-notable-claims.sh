#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-takes-notable-claims.sh   (FIX-TK-2)
#
# WHY THIS EXISTS
# The v0.42 takes pipeline (extract-takes-from-pages.ts) is RUNNING on the live
# container (takes.bootstrap_enabled = true) but its output is invisible to any
# reader. The fidelity audit (docs/brain-audit-2026-06-05/03-fidelity-audit.md)
# measured ~19% essence retention on entity pages: the brain keeps commodity
# facts and loses the analyst TAKES (quantified / contrarian / predictive
# claims). Root cause, confirmed in code — three distinct gaps:
#
#   1. No writeTakesToFence. extract-takes-from-pages.ts flushes via
#      engine.addTakesBatch(...) — a DB-only `INSERT INTO takes`. The `## Takes`
#      fence renderer/parser (takes-fence.ts: upsertTakeRow / renderTakesFence /
#      parseTakesFence) exist, but nothing on the write path calls them, so a
#      take never lands in the page BODY. compiled_truth IS the page body
#      (markdown.ts), so a DB-only take is invisible to get_page / a reader.
#      Facts solved this in v0.32.2 with writeFactsToFence (facts/fence-write.ts);
#      takes never got the equivalent.
#
#   2. Extraction skips the page types that carry the value. ALLOWED_PAGE_TYPES
#      is concept/atom/lore/briefing/writing/originals — it never touches
#      `source`, `person`, or `company`. The alpha lives in `source` transcripts
#      (rich compiled_truth) and should land on person/company pages.
#
#   3. No subject routing / holder attribution. Every take is stored with
#      page_id = page.id (the page it was READ from) and holder = opts.holder ??
#      'system'. A take mined from a source transcript is keyed to the SOURCE
#      page, authored by 'system' — not routed to the entity it is ABOUT, nor
#      attributed to the speaker. Facts already do this (facts/backstop.ts:425
#      "Phase 5: fence-write per entity").
#
# Schema note: the `takes` table is PAGE-SCOPED (UNIQUE (page_id, row_num)). The
# page a take lives on IS its subject; holder is the speaker. So there is NO
# schema migration — exactly the facts model. This patch is purely code.
#
# ── WHAT THIS PATCH DOES (three parts, mirroring FIX-TK-2 DESIGN.md) ──────────
#   Part A: write two NEW files under src/core/takes/ —
#             fence-write.ts (writeTakesToFence; mirrors facts/fence-write.ts)
#             route.ts       (resolveTakeSubjects + resolveSpeaker; the only
#                             genuinely new logic, mirrors facts/backstop.ts
#                             Phase-5 per-entity resolution)
#   Part B: widen ALLOWED_PAGE_TYPES to add 'source','person','company'.
#   Part C: replace the per-page DB-only push-loop in extractTakesFromPages with
#           a per-subject-entity writeTakesToFence loop (speaker as holder),
#           keeping the DB-only `batch`/`flush()` path as the fallback sink for
#           stubGuardBlocked / legacyFallback and the no-subject→origin case.
#
# ── ANCHOR STRATEGY ──────────────────────────────────────────────────────────
# PREFLIGHT self-audits every anchor it will touch and EXITS NON-ZERO if any is
# gone, so a moved anchor FAILS THE DOCKER BUILD (old container keeps serving)
# rather than silently no-oping. Idempotency: a single sentinel `FIX-TK-2` (in
# the new files' header AND injected at each edit site) makes a re-run a no-op.
#
# This is a gbrain *core* modification. Applied at Docker BUILD time after the
# gbrain install; baked in; re-applied on every GBRAIN_REF bump. Idempotent.
#
# RISK: high. Parts B/C change WHAT gets extracted and WHERE it lands — a
# behavioral change to a pipeline gated behind an eval suite upstream. The
# preferred long-term home is an upstream PR to garrytan/gbrain (see DESIGN.md);
# this build-time patch is the interim carry. deprecate_when fires when that PR
# merges and GBRAIN_REF advances past it.
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
  echo "[gbrain-patch:tk-2] ERROR: gbrain src tree not found; nothing patched." >&2
  exit 1
fi
echo "[gbrain-patch:tk-2] target: $GBRAIN_SRC"

EXTRACT_FILE="$GBRAIN_SRC/core/extract-takes-from-pages.ts"
FENCE_SRC="$GBRAIN_SRC/core/takes-fence.ts"
TAKES_DIR="$GBRAIN_SRC/core/takes"
FENCE_WRITE_FILE="$TAKES_DIR/fence-write.ts"
ROUTE_FILE="$TAKES_DIR/route.ts"

for f in "$EXTRACT_FILE" "$FENCE_SRC"; do
  if [ ! -f "$f" ]; then
    echo "[gbrain-patch:tk-2] ERROR: $f not found." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 2. PREFLIGHT — self-audit every anchor BEFORE any edit. A moved anchor fails
#    the Docker build (exit non-zero) rather than silently no-oping.
# ---------------------------------------------------------------------------
echo "[gbrain-patch:tk-2] preflight: auditing anchors..."

PF_FAIL=0

# --- Part B anchor: the ALLOWED_PAGE_TYPES list (extract-takes-from-pages.ts:20-22) ---
B_ANCHOR_OPEN="export const ALLOWED_PAGE_TYPES = ["
B_ANCHOR_BODY="  'concept', 'atom', 'lore', 'briefing', 'writing', 'originals',"
if ! grep -qF "$B_ANCHOR_OPEN" "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] ERROR: Part-B anchor ('export const ALLOWED_PAGE_TYPES = [') gone from extract-takes-from-pages.ts — RE-POINT (see UPGRADING_GBRAIN.md)." >&2
  PF_FAIL=1
fi
if ! grep -qF "$B_ANCHOR_BODY" "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] ERROR: Part-B anchor (ALLOWED_PAGE_TYPES body line) gone from extract-takes-from-pages.ts — RE-POINT." >&2
  PF_FAIL=1
fi

# --- Part C anchor: the addTakesBatch DB-only flush (extract-takes-from-pages.ts:155) ---
C_ANCHOR_FLUSH="claimsExtracted += await engine.addTakesBatch(batch);"
if ! grep -qF "$C_ANCHOR_FLUSH" "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] ERROR: Part-C anchor ('claimsExtracted += await engine.addTakesBatch(batch);') gone from extract-takes-from-pages.ts — RE-POINT." >&2
  PF_FAIL=1
fi

# --- Part C anchor: the per-page push-loop region we replace (extract-takes-from-pages.ts:201-213) ---
C_ANCHOR_LOOP_OPEN="    for (let i = 0; i < claims.length; i++) {"
C_ANCHOR_LOOP_END="    if (batch.length >= 200) await flush();"
if ! grep -qF "$C_ANCHOR_LOOP_OPEN" "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] ERROR: Part-C anchor (per-page claims push-loop opener) gone from extract-takes-from-pages.ts — RE-POINT." >&2
  PF_FAIL=1
fi
if ! grep -qF "$C_ANCHOR_LOOP_END" "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] ERROR: Part-C anchor ('if (batch.length >= 200) await flush();') gone from extract-takes-from-pages.ts — RE-POINT." >&2
  PF_FAIL=1
fi

# --- Part C anchor: import insertion site (the ai/gateway import line) ---
C_ANCHOR_IMPORT="import { chat, isAvailable } from './ai/gateway.ts';"
if ! grep -qF "$C_ANCHOR_IMPORT" "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] ERROR: Part-C anchor (ai/gateway import line) gone from extract-takes-from-pages.ts — RE-POINT." >&2
  PF_FAIL=1
fi

# --- Part C anchors: the PageRow interface + the SELECT that populates it. We
#     add `frontmatter` to both so resolveSpeaker can read source frontmatter
#     (the SELECT currently omits it). These anchors are SUBSTRING-STABLE —
#     they survive our own C.1b edit so the preflight stays green on re-run
#     (idempotency). C.1b itself is guarded by its own already-applied grep. ---
C_ANCHOR_PAGEROW="  compiled_truth: string;"
C_ANCHOR_SELECT="    \`SELECT id, slug, source_id, type, compiled_truth,"
if ! grep -qF "$C_ANCHOR_PAGEROW" "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] ERROR: Part-C anchor (PageRow.compiled_truth field) gone from extract-takes-from-pages.ts — RE-POINT." >&2
  PF_FAIL=1
fi
if ! grep -qF "$C_ANCHOR_SELECT" "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] ERROR: Part-C anchor (eligible-pages SELECT column-list prefix) gone from extract-takes-from-pages.ts — RE-POINT." >&2
  PF_FAIL=1
fi

# --- Part A anchors: takes-fence.ts exports that fence-write.ts imports ---
#     (upsertTakeRow, parseTakesFence, isValidHolder, TakeKind, the fence markers).
for sym in \
  "export function upsertTakeRow(" \
  "export function parseTakesFence(" \
  "export function isValidHolder(" \
  "export type TakeKind = string;" \
  "export const TAKES_FENCE_BEGIN" \
  "export const TAKES_FENCE_END"; do
  if ! grep -qF "$sym" "$FENCE_SRC"; then
    echo "[gbrain-patch:tk-2] ERROR: Part-A anchor ('$sym') gone from takes-fence.ts — fence-write.ts import would break. RE-POINT." >&2
    PF_FAIL=1
  fi
done

if [ "$PF_FAIL" = "1" ]; then
  echo "[gbrain-patch:tk-2] ERROR: preflight anchor audit failed — see errors above. Nothing patched." >&2
  exit 1
fi
echo "[gbrain-patch:tk-2] preflight: all anchors present."

# ---------------------------------------------------------------------------
# 3. PART A — write src/core/takes/fence-write.ts and src/core/takes/route.ts
#    Idempotency: skip if the file already carries the FIX-TK-2 sentinel.
# ---------------------------------------------------------------------------
mkdir -p "$TAKES_DIR"

# ---- Part A.1 — fence-write.ts -------------------------------------------------
if [ -f "$FENCE_WRITE_FILE" ] && grep -qF 'FIX-TK-2' "$FENCE_WRITE_FILE"; then
  echo "[gbrain-patch:tk-2] [A.1] ✓ takes/fence-write.ts already present (FIX-TK-2 sentinel); no-op."
else
  echo "[gbrain-patch:tk-2] [A.1] writing takes/fence-write.ts..."
  cat > "$FENCE_WRITE_FILE" <<'FENCEWRITE_EOF'
// src/core/takes/fence-write.ts
//
// FIX-TK-2 / Part A — markdown-first take write path.
//
// Sister to `src/core/facts/fence-write.ts` (writeFactsToFence, v0.32.2).
// gbrain's "system of record" invariant: a take must land in the entity
// page's `## Takes` fence FIRST (git-canonical markdown), then the DB
// `takes` table is stamped as a derived index. Today `extract-takes-from-
// pages.ts` skips the markdown and writes DB-only via `addTakesBatch`, so
// takes never appear in `compiled_truth` / `get_page` — the v0.42 takes
// pipeline produces value that no reader can see. This module closes that.
//
// Mirrors the facts path exactly: page-lock → read-or-stub-create → append
// each take to the `## Takes` fence via `upsertTakeRow` → atomic .tmp write
// + parse-validate + rename → stamp the DB index by resolved page_id.
//
// Re-verified against live pin 099d9a8 (v0.42.34.0): all imported symbols
// (BrainEngine, TakeBatchInput, withPageLock, upsertTakeRow, parseTakesFence,
// isValidHolder, TakeKind) confirmed present with the verified signatures
// below. Two drifts corrected vs the v0.42.26.0 draft — see the inline
// VERIFIED notes at the addTakesBatch call site.

import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { join, dirname } from 'node:path';

import type { BrainEngine, TakeBatchInput } from '../engine.ts';
import type { TakeKind } from '../takes-fence.ts';
import { withPageLock } from '../page-lock.ts';
import {
  upsertTakeRow,
  parseTakesFence,
  isValidHolder,
} from '../takes-fence.ts';

/** Resolved source binding for the entity page (same shape as facts FenceTarget). */
export interface TakeFenceTarget {
  /** Source primary key, e.g. 'default'. */
  sourceId: string;
  /** Filesystem root for this source. Null when the brain is read-only / thin-client. */
  localPath: string | null;
  /** Entity slug — also the file basename. MUST be directory-prefixed (people/, companies/, …). */
  slug: string;
}

/** One take prepared by the extractor (post-classify). */
export interface FenceInputTake {
  claim: string;
  kind: TakeKind;            // 'fact' | 'take' | 'bet' | 'hunch' | (open string post-v0.38)
  /** Who HOLDS the belief — the speaker. Falls back to 'system' if invalid/absent. */
  holder: string;
  /** [0,1]; clamped at the engine layer. Defaults to 0.5 in the fence renderer. */
  weight?: number;
  sinceDate?: string;
  untilDate?: string;
  /** Provenance string, e.g. 'cli:takes-bootstrap-from-pages' or 'source:<slug>'. */
  source: string;
}

export interface TakeFenceWriteResult {
  /** Number of take rows written to the fence + indexed. */
  inserted: number;
  /** Assigned fence row_nums, in input order. */
  rowNums: number[];
  /** True when localPath was null — caller falls through to DB-only addTakesBatch. */
  legacyFallback?: true;
  /** True when parse-validate of the .tmp failed; rows NOT written, .tmp quarantined. */
  fenceWriteFailed?: true;
  /** True when the stub guard refused a phantom unprefixed-slug page; caller routes DB-only. */
  stubGuardBlocked?: true;
}

/**
 * FIX-TK-2: filler words dropped during claim normalization. These are the
 * articles / hedges / approximation qualifiers that a paraphrase swaps in or
 * out without changing the underlying assertion ("one of ONLY three" vs "one
 * of three"; "ROUGHLY $40B" vs "$40B"). Deliberately SMALL and conservative —
 * it must NOT include any word whose presence/absence changes meaning, and it
 * NEVER touches digits, so two claims with different numbers or entities stay
 * distinct.
 */
const _CLAIM_FILLER_WORDS = new Set([
  'the', 'a', 'an', 'of', 'is', 'are', 'to', 'in', 'for', 'and',
  'only', 'nearly', 'roughly', 'about', 'approximately', 'around',
  'circa',
]);

/**
 * FIX-TK-2: normalize a claim to a dedup key. Lowercase, replace every
 * non-alphanumeric run with a single space, drop filler words, collapse and
 * trim whitespace. Digits are PRESERVED (and word-internal alphanumerics like
 * "37.4b" → "37 4b" stay), so distinct numbers/entities produce distinct keys
 * — only filler-word rewordings of the same assertion collapse to one key.
 * Returns '' when the claim has no alphanumeric content.
 */
function _normClaim(claim: string): string {
  return (claim ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .split(' ')
    .filter((w) => w && !_CLAIM_FILLER_WORDS.has(w))
    .join(' ')
    .trim();
}

// FIX-TK-2-A (slug-collision guard): only stub-create a page for a real ENTITY
// subject dir. NEVER for a source slug (e.g. sources/youtube/<id>): gbrain
// lowercases slugs, so a source slug lowercases to a twin of the collector's
// case-preserving filename, and stub-creating here mints a colliding
// type:concept page that clobbers the real type:source page (shadowing its
// content + dates). Mirrors route.ts SUBJECT_DIRS; a non-subject-dir slug is
// routed to the DB-only fallback (page_id = origin row) instead.
const STUB_SUBJECT_DIRS = new Set(['people', 'companies', 'concepts', 'topics', 'deals', 'deal']);

/** Minimum canonical body for a brand-new entity page (mirrors facts stubEntityPage). */
function stubEntityPage(slug: string): string {
  const prefix = slug.split('/')[0];
  const type =
    prefix === 'people'    ? 'person'  :
    prefix === 'companies' ? 'company' :
    prefix === 'deals'     ? 'deal'    :
    prefix === 'topics'    ? 'concept' :
    /* fallback */           'concept';
  const tail = slug.split('/').slice(1).join('/');
  const title = tail.replace(/[-_/]+/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase()) || slug;
  return `---\ntype: ${type}\ntitle: ${title}\nslug: ${slug}\n---\n\n# ${title}\n`;
}

/**
 * Markdown-first take write for ONE entity page. Returns legacyFallback when
 * the brain has no local_path (thin-client), stubGuardBlocked when the slug is
 * unprefixed (no phantom root pages), fenceWriteFailed when the re-parse of the
 * just-written body doesn't round-trip (the .tmp is left as quarantine evidence
 * and the DB is NOT touched).
 */
export async function writeTakesToFence(
  engine: BrainEngine,
  target: TakeFenceTarget,
  takes: FenceInputTake[],
): Promise<TakeFenceWriteResult> {
  if (target.localPath === null) return { inserted: 0, rowNums: [], legacyFallback: true };
  if (takes.length === 0) return { inserted: 0, rowNums: [] };

  const filePath = join(target.localPath, `${target.slug}.md`);
  const tmpPath = `${filePath}.tmp`;

  // VERIFIED 099d9a8: withPageLock(slug, fn, opts?) — page-lock.ts:148. The
  // facts path passes { timeoutMs: 5_000 }; mirror it so a contended page
  // fails fast (5s) rather than blocking on the 30s default.
  return withPageLock(
    target.slug,
    async (): Promise<TakeFenceWriteResult> => {
      // 1. Read existing body or stub-create (with the unprefixed-slug guard).
      let body: string;
      if (existsSync(filePath)) {
        body = readFileSync(filePath, 'utf-8');
      } else {
        if (!STUB_SUBJECT_DIRS.has(target.slug.split('/')[0])) {
          // FIX-TK-2-A: only stub-create for a real entity subject dir (people/
          // companies/concepts/topics/deals). This BLOCKS both the original
          // unprefixed-phantom-root case AND a source slug (sources/youtube/<id>),
          // which would otherwise mint a colliding type:concept page that
          // clobbers the real type:source page at the same lowercased slug.
          // Caller routes these takes to the legacy DB-only path (page_id =
          // origin row) so they are dated/graded/searchable — just not rendered
          // in the source page body (acceptable for a no-subject source take).
          // eslint-disable-next-line no-console
          console.warn(
            `[takes] refusing to stub-create non-subject-dir page slug=${target.slug} — routing to legacy DB-only path.`,
          );
          return { inserted: 0, rowNums: [], stubGuardBlocked: true };
        }
        mkdirSync(dirname(filePath), { recursive: true });
        body = stubEntityPage(target.slug);
      }

      // 2. Append each take to the `## Takes` fence (append-only; monotonic row_num).
      //    FIX-TK-2: normalized-claim dedup. The extractor re-runs over the same
      //    source pages and frequently re-emits a reworded restatement of a claim
      //    already on the fence ("one of only three HBM suppliers" vs "one of
      //    three HBM suppliers"). Suppress those near-duplicates so the fence
      //    doesn't accrete paraphrases. CRITICAL: we DO NOT strip digits — two
      //    claims with different NUMBERS or ENTITIES normalize differently and
      //    both survive ("$37.4B revenue" != "$23.86B revenue"); only filler-word
      //    rewordings collapse. Seed the dedup set from the claims ALREADY in the
      //    fence so a re-run is idempotent.
      const seenClaims = new Set<string>();
      for (const pt of parseTakesFence(body).takes) {
        const k = _normClaim(pt.claim);
        if (k) seenClaims.add(k);
      }
      const rowNums: number[] = [];
      const insertedTakes: FenceInputTake[] = [];
      for (const t of takes) {
        const key = _normClaim(t.claim);
        // Empty after normalization (no alphanumerics) or already present
        // (exact OR reworded restatement) → skip; don't append a duplicate row.
        if (!key || seenClaims.has(key)) continue;
        seenClaims.add(key);
        const holder = isValidHolder(t.holder) ? t.holder : 'system';
        const { body: updated, rowNum } = upsertTakeRow(body, {
          claim:     t.claim,
          kind:      t.kind,
          holder,
          weight:    t.weight ?? 0.5,
          sinceDate: t.sinceDate,
          untilDate: t.untilDate,
          source:    t.source,
          active:    true,
        });
        body = updated;
        rowNums.push(rowNum);
        insertedTakes.push(t);
      }

      // 3. Atomic write: .tmp → parse-validate → rename. Quarantine on failure.
      writeFileSync(tmpPath, body, 'utf-8');
      const { warnings } = parseTakesFence(body);
      if (warnings.length > 0) {
        // Leave .tmp in place as evidence; do NOT rename, do NOT touch the DB.
        // eslint-disable-next-line no-console
        console.warn(`[takes] fence parse-validate failed for ${target.slug}: ${warnings.join('; ')}`);
        return { inserted: 0, rowNums: [], fenceWriteFailed: true };
      }
      renameSync(tmpPath, filePath);

      // 4. Stamp the DB index (derived). Resolve page_id by slug; markdown stays
      //    canonical, so a failure here is non-fatal (next sync re-derives).
      try {
        // VERIFIED 099d9a8: gbrain slugs are unique PER SOURCE, not globally —
        // every page lookup in postgres-engine.ts scopes by source_id
        // (e.g. :1062, :2054, :2241). Scope the resolution by target.sourceId
        // so a multi-source brain can't index against another source's page.
        const rows = await engine.executeRaw<{ id: number }>(
          `SELECT id FROM pages WHERE slug = $1 AND source_id = $2 AND deleted_at IS NULL LIMIT 1`,
          [target.slug, target.sourceId],
        );
        const pageId = rows[0]?.id;
        if (pageId !== undefined) {
          // VERIFIED 099d9a8: TakeBatchInput (engine.ts:245) date columns are
          // `since_date` / `until_date` — NOT `since`. buildTakeRows
          // (batch-rows.ts:151-152) reads r.since_date / r.until_date, and the
          // INSERT (postgres-engine.ts:4010) writes since_date/until_date. The
          // v0.42.26.0 draft used `since: t.sinceDate`, which both fails the
          // excess-property check on this literal AND would silently drop the
          // date even if it compiled. Corrected to since_date/until_date.
          // FIX-TK-2: index ONLY the takes actually appended to the fence
          // (insertedTakes), aligned 1:1 with rowNums. Dedup-suppressed takes
          // are not on the fence, so they must not be stamped into the DB index.
          const batch: TakeBatchInput[] = insertedTakes.map((t, i) => ({
            page_id: pageId,
            row_num: rowNums[i],
            claim: t.claim,
            kind: t.kind,
            holder: isValidHolder(t.holder) ? t.holder : 'system',
            weight: t.weight ?? 0.5,
            since_date: t.sinceDate,
            until_date: t.untilDate,
            source: t.source,
            active: true,
          }));
          // VERIFIED 099d9a8: addTakesBatch(rows, opts?) → Promise<number>
          // (engine.ts:1402). Return value (insert count) is intentionally
          // ignored — `inserted` below reflects fence rows, the canonical truth.
          if (batch.length > 0) await engine.addTakesBatch(batch);
        }
        // pageId undefined → brand-new stub not yet imported; next `gbrain sync`
        // parses the fence into the takes table. Markdown is the source of truth.
      } catch {
        // Non-fatal: the fence (canonical) is written; DB index re-derives on sync.
      }

      // FIX-TK-2: report ACTUAL inserts (fence rows written), not the input
      // length — dedup-suppressed near-duplicates are not counted.
      return { inserted: rowNums.length, rowNums };
    },
    { timeoutMs: 5_000 },
  );
}
FENCEWRITE_EOF
  if ! grep -qF 'FIX-TK-2' "$FENCE_WRITE_FILE"; then
    echo "[gbrain-patch:tk-2] ERROR: takes/fence-write.ts written but FIX-TK-2 sentinel missing — heredoc failed." >&2
    exit 1
  fi
  echo "[gbrain-patch:tk-2] [A.1] ✓ takes/fence-write.ts written."
fi

# ---- Part A.2 — route.ts -------------------------------------------------------
if [ -f "$ROUTE_FILE" ] && grep -qF 'FIX-TK-2' "$ROUTE_FILE"; then
  echo "[gbrain-patch:tk-2] [A.2] ✓ takes/route.ts already present (FIX-TK-2 sentinel); no-op."
else
  echo "[gbrain-patch:tk-2] [A.2] writing takes/route.ts..."
  cat > "$ROUTE_FILE" <<'ROUTE_EOF'
// src/core/takes/route.ts
//
// FIX-TK-2 / Part C — subject routing + speaker attribution for takes.
//
// The only genuinely NEW logic in FIX-TK-2. Parts A (`takes/fence-write.ts`)
// and B (`ALLOWED_PAGE_TYPES` widening) are mechanical mirrors of the facts
// path; this module is the takes analogue of `facts/backstop.ts` Phase 5's
// per-entity resolution (the `resolveEntitySlug` subject loop) PLUS the
// speaker (`holder`) derivation that facts don't need (facts have no holder).
//
// Two exports, both mirroring how the facts pipeline resolves entities at the
// live pin (gbrain v0.42.34.0 / 099d9a8):
//
//   resolveTakeSubjects(engine, page, claimText)
//     → the entity slug(s) a claim is ABOUT. Prefers explicit markdown /
//       wikilink entity refs in the claim text (the Iron-Law back-links the
//       extractor already honours — `extractEntityRefs`, link-extraction.ts:300),
//       falls back to an NER pass over the claim text (`buildGazetteer` +
//       `findMentionedEntities`, by-mention.ts:155/229 — the SAME pass
//       `extract-ner.ts:166` runs). Returns de-duped, directory-prefixed slugs
//       (people/ companies/ concepts/ …), self-ref (the origin page) removed.
//       Empty array → caller keeps the origin page (no regression).
//
//   resolveSpeaker(engine, page)
//     → the `holder` (who SAID/endorsed the claim) for a take extracted from
//       this page. For a `person` page: the page subject. For a `source`
//       page: a frontmatter-derived speaker (`speaker`/`host`/`author_*`/
//       `participants`/`channel`/`podcast`, resolved through
//       `resolveEntitySlug`, entities/resolve.ts:41) or, failing that, the
//       dominant outbound author/works_at edge (`getLinks`, engine.ts:1140).
//       Otherwise ''. '' tells the caller to fall back to `opts.holder` /
//       'system' — never invents a phantom holder.
//
// FIX-TK-2 sentinel (idempotency marker for the build patch).
// Paths/imports assume placement at src/core/takes/route.ts, so siblings in
// src/core/ are reached via `../`.

import type { BrainEngine } from '../engine.ts';
// VERIFIED 099d9a8: `Link` is declared in types.ts (:1153) and only `import
// type`'d (not re-exported) by engine.ts — importing it from '../engine.ts'
// fails TS2459. `Page` lives here too.
import type { Page, Link } from '../types.ts';
import { extractEntityRefs } from '../link-extraction.ts';
import { buildGazetteer, findMentionedEntities, type Gazetteer } from '../by-mention.ts';
import { resolveEntitySlug } from '../entities/resolve.ts';

/**
 * Directory prefixes we accept as a take SUBJECT. A take is always ABOUT an
 * entity-shaped page; routing a claim onto `daily/2026-06-08` or
 * `meetings/standup` is never what we want. Mirrors the entity dirs the facts
 * stub-create path recognises (`facts/fence-write.ts` stubEntityPage) plus the
 * `concepts`/`topics` taxonomy a `concept`-typed claim subject lives under.
 */
const SUBJECT_DIRS = new Set([
  'people',
  'companies',
  'concepts',
  'topics',
  'deals',
  'deal',
]);

/**
 * Frontmatter fields that name the speaker on a `source` page, in priority
 * order. Grounded in the live brain's real source frontmatter shapes
 * (hermes-brain/sources/*):
 *   - x-bookmarks pages → `author_name` / `author_handle`   (the tweeter)
 *   - snipd pages       → `host` (13 pages carry it) / `podcast`
 *   - youtube pages     → `channel` (show/host name)
 * `speaker` / `participants` are forward-compat (no live page carries them
 * today, but a richer collector might). First field that resolves to a real
 * prefixed `people/` page wins.
 */
const SPEAKER_FRONTMATTER_FIELDS = [
  'speaker',
  'host',
  'author_name',
  'author_handle',
  'participants',
  'channel',
  'podcast',
] as const;

/** Link verbs that point a source/person page at its author / speaker. */
const AUTHOR_EDGE_TYPES = new Set([
  'authored_by',
  'author',
  'spoken_by',
  'hosted_by',
  'works_at',
  'created_by',
]);

// ============================================================
// Subjects — what the claim is ABOUT
// ============================================================

/**
 * Resolve the entity slug(s) a claim is about.
 *
 * Resolution order (prefer explicit markup, fall back to NER — exactly the
 * order facts use when it has explicit `entity_slug` hints vs. a free-text
 * resolve):
 *
 *   1. Explicit entity references in the claim text. `extractEntityRefs`
 *      parses `[Name](../companies/x.md)` markdown links AND `[[people/y]]`
 *      wikilinks, returning `{ slug, dir }`. We keep only refs whose `dir` is
 *      a SUBJECT_DIR and whose slug is directory-prefixed; bare
 *      `needsResolution` refs (generic `[[bare-name]]`) are dropped (they'd
 *      need a SlugResolver round-trip the extractor doesn't have here, and a
 *      mis-resolution would mint a phantom subject page — the same failure
 *      mode the facts stub-guard exists to prevent).
 *
 *   2. NER fallback (only when step 1 found nothing). Build the brain
 *      gazetteer once (or reuse the caller-supplied one) and run
 *      `findMentionedEntities` over the claim text — the identical NER pass
 *      `extract-ner.ts` runs over page bodies. The gazetteer is restricted to
 *      entity-typed pages by construction, so every hit is already an entity
 *      slug; `findMentionedEntities` self-link-guards against the origin page.
 *
 * Output: de-duped, directory-prefixed slugs. The origin page's own slug is
 * removed (a take routed back to the page it was read from is the no-subject
 * case, handled by the caller). Empty array → caller keeps the origin page.
 *
 * `gazetteer` is optional: the extractor builds it ONCE per run and threads it
 * in so we don't pay a full `buildGazetteer` per claim (it's a brain-wide
 * scan). Omitted → we build a throwaway one (correct, just slower).
 */
export async function resolveTakeSubjects(
  engine: BrainEngine,
  page: Pick<Page, 'slug' | 'source_id'>,
  claimText: string,
  gazetteer?: Gazetteer,
): Promise<string[]> {
  const text = (claimText ?? '').trim();
  if (!text) return [];

  const out = new Set<string>();

  // --- 1. Explicit entity refs in the claim text (Iron-Law back-links). ---
  for (const ref of extractEntityRefs(text)) {
    if (ref.needsResolution) continue; // generic [[bare-name]] — skip (see docstring)
    const slug = normalizeRefSlug(ref.slug);
    if (!isPrefixedSubjectSlug(slug)) continue;
    if (slug === page.slug) continue; // self-ref → no-subject case
    out.add(slug);
  }

  if (out.size > 0) {
    return [...out];
  }

  // --- 2. NER fallback over the claim text (no explicit refs found). ---
  // Same pass extract-ner.ts runs over page bodies. Gazetteer is entity-typed
  // by construction, so each mention is already an entity slug.
  let gaz = gazetteer;
  if (!gaz) {
    try {
      gaz = await buildGazetteer(engine);
    } catch {
      return []; // gazetteer build failed → no subjects; caller keeps origin page
    }
  }
  if (gaz.size === 0) return [];

  const mentions = findMentionedEntities(text, gaz, {
    fromSlug: page.slug,
    fromSourceId: page.source_id,
  });
  for (const m of mentions) {
    // findMentionedEntities already self-link-guards and cross-source-guards.
    // Keep only entity-dir-prefixed slugs (the gazetteer is entity-typed, but
    // be defensive about a top-level entity page with no prefix).
    if (!isPrefixedSubjectSlug(m.slug)) continue;
    out.add(m.slug);
  }

  return [...out];
}

// ============================================================
// Speaker — who HELD / SAID the claim (the take `holder`)
// ============================================================

/**
 * Resolve the `holder` for takes extracted from `page`.
 *
 * Returns a holder string in the takes-fence grammar
 * (`people/<slug>` | `companies/<slug>`; bare slugs are tolerated by the
 * fence's legacy-compat grammar but we always emit a prefixed form). Returns
 * '' when no speaker can be determined — the caller treats '' as "fall back to
 * opts.holder / 'system'", never inventing a phantom holder (the holder/subject
 * confusion the takes-fence JSDoc flags as the #1 attribution error).
 *
 * Derivation:
 *   - `person` page  → the page subject is the speaker (their own slug, already
 *     prefixed). This is the take-on-a-person-page case from Part B.
 *   - `source` page  → (a) frontmatter speaker fields in priority order,
 *     resolved through `resolveEntitySlug` and accepted ONLY when the resolve
 *     produced a real directory-prefixed page (a bare slugify fallback means
 *     "no such person page" — we don't mint a phantom holder); else
 *     (b) the dominant outbound author/works_at edge from `getLinks`.
 *   - anything else  → ''.
 */
export async function resolveSpeaker(
  engine: BrainEngine,
  page: Pick<Page, 'slug' | 'type' | 'source_id' | 'frontmatter'>,
): Promise<string> {
  // person page: the subject IS the speaker.
  if (page.type === 'person') {
    return isPrefixedSubjectSlug(page.slug) ? page.slug : `people/${page.slug}`;
  }

  // Only source pages carry a meaningful external speaker. Everything else
  // (concept/atom/writing/…) has no single speaker → caller's default holder.
  if (page.type !== 'source') return '';

  // (a) Frontmatter-named speaker, resolved to a real prefixed person page.
  const fm = page.frontmatter ?? {};
  for (const field of SPEAKER_FRONTMATTER_FIELDS) {
    const raw = firstString(fm[field]);
    if (!raw) continue;
    let resolved: string | null = null;
    try {
      resolved = await resolveEntitySlug(engine, page.source_id, raw);
    } catch {
      resolved = null;
    }
    // Accept ONLY a directory-prefixed result. resolveEntitySlug's fallback is
    // a bare slugify (no prefix) which means "no matching page" — taking it
    // would spawn a phantom holder (the bug the facts stub-guard prevents).
    if (resolved && resolved.includes('/')) {
      return resolved;
    }
  }

  // (b) Dominant outbound author/works_at edge. getLinks returns OUTGOING
  // edges (from_slug === page.slug). Count by target; the most-linked
  // author/works_at target is the speaker.
  let links: Link[] = [];
  try {
    links = await engine.getLinks(page.slug, { sourceId: page.source_id });
  } catch {
    links = [];
  }
  const counts = new Map<string, number>();
  for (const l of links) {
    if (!AUTHOR_EDGE_TYPES.has(l.link_type)) continue;
    const to = normalizeRefSlug(l.to_slug);
    if (!isPrefixedSubjectSlug(to)) continue;
    if (to === page.slug) continue;
    counts.set(to, (counts.get(to) ?? 0) + 1);
  }
  if (counts.size > 0) {
    // Highest count wins; slug-ASC tiebreak for determinism (matches the
    // facts prefix-expansion tiebreaker posture).
    const best = [...counts.entries()].sort(
      (a, b) => b[1] - a[1] || a[0].localeCompare(b[0]),
    )[0];
    return best[0];
  }

  return '';
}

// ============================================================
// Helpers
// ============================================================

/**
 * Normalize a slug as it appears in a markdown ref or links row to the
 * canonical engine slug shape: drop any leading `../`, drop a trailing `.md`,
 * drop a `#anchor`, lowercase. Mirrors the normalization extractEntityRefs
 * itself applies, applied again defensively for edge rows that bypass it.
 */
function normalizeRefSlug(raw: string): string {
  let s = (raw ?? '').trim();
  if (!s) return '';
  s = s.replace(/^(?:\.\.\/)+/, '');
  const hash = s.indexOf('#');
  if (hash !== -1) s = s.slice(0, hash);
  if (s.endsWith('.md')) s = s.slice(0, -3);
  return s.toLowerCase();
}

/**
 * True when the slug is directory-prefixed AND the prefix is a recognised
 * SUBJECT_DIR. The prefix gate is the same wall the facts stub-guard enforces
 * (`writeFactsToFence` refuses to stub-create an unprefixed bare slug): an
 * unprefixed slug would route a take onto a phantom brain-root page.
 */
function isPrefixedSubjectSlug(slug: string): boolean {
  if (!slug || !slug.includes('/')) return false;
  const prefix = slug.split('/')[0];
  return SUBJECT_DIRS.has(prefix);
}

/**
 * Coerce a frontmatter value into a single display string. Handles the scalar
 * case (`author_name: "Garry Tan"`) and the list case (`participants:
 * [garry-tan, bo-lu]` → first element). Returns '' for empty / non-stringable
 * values. We deliberately take only the FIRST participant — a take's speaker is
 * one person; multi-speaker attribution is out of scope (and would need
 * per-claim diarization the extractor doesn't have).
 */
function firstString(v: unknown): string {
  if (typeof v === 'string') return v.trim();
  if (Array.isArray(v)) {
    for (const item of v) {
      if (typeof item === 'string' && item.trim()) return item.trim();
    }
  }
  return '';
}
ROUTE_EOF
  if ! grep -qF 'FIX-TK-2' "$ROUTE_FILE"; then
    echo "[gbrain-patch:tk-2] ERROR: takes/route.ts written but FIX-TK-2 sentinel missing — heredoc failed." >&2
    exit 1
  fi
  echo "[gbrain-patch:tk-2] [A.2] ✓ takes/route.ts written."
fi

# ---------------------------------------------------------------------------
# 4. PART B — widen ALLOWED_PAGE_TYPES to add 'source','person','company'.
#    Idempotent: skip if already present.
# ---------------------------------------------------------------------------
echo "[gbrain-patch:tk-2] [B] widening ALLOWED_PAGE_TYPES..."

if grep -qF "'source', 'person', 'company'," "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] [B] ✓ already widened ('source','person','company' present); no-op."
else
  B_OLD="  'concept', 'atom', 'lore', 'briefing', 'writing', 'originals',"
  B_NEW="  'concept', 'atom', 'lore', 'briefing', 'writing', 'originals',
  // FIX-TK-2 (Part B): mine the page types that actually carry analyst takes.
  // 'source' pages have the richest compiled_truth (transcript + Key Takeaways);
  // 'person'/'company' lets a take that names no other entity stay on the page
  // it was read from. Cost stays bounded by maxPages + the 20K-char truncation.
  'source', 'person', 'company',"

  export B_OLD B_NEW
  perl -0777 -i -pe '
    my $o = $ENV{B_OLD};
    my $n = $ENV{B_NEW};
    s/\Q$o\E/$n/ unless /'"'"'source'"'"', '"'"'person'"'"', '"'"'company'"'"',/;
  ' "$EXTRACT_FILE"

  if ! grep -qF "'source', 'person', 'company'," "$EXTRACT_FILE"; then
    echo "[gbrain-patch:tk-2] ERROR: [B] ALLOWED_PAGE_TYPES widen did not land. RE-POINT." >&2
    exit 1
  fi
  echo "[gbrain-patch:tk-2] [B] ✓ ALLOWED_PAGE_TYPES now includes source/person/company."
fi

# ---------------------------------------------------------------------------
# 5. PART C — replace the per-page DB-only push-loop with a per-subject-entity
#    writeTakesToFence loop. The DB-only `batch`/`flush()` path is KEPT as the
#    fallback sink for stubGuardBlocked / legacyFallback; the no-subject case
#    routes the take to its ORIGIN page (no regression).
#
#    Two edits:
#      C.1: add the imports (after the ai/gateway import line).
#      C.2: replace the push-loop region (`for (let i...` through
#           `if (batch.length >= 200) await flush();`) with the new loop.
# ---------------------------------------------------------------------------
echo "[gbrain-patch:tk-2] [C] wiring writeTakesToFence into the extractor..."

if grep -qF 'FIX-TK-2-WIRING' "$EXTRACT_FILE"; then
  echo "[gbrain-patch:tk-2] [C] ✓ already applied (FIX-TK-2-WIRING sentinel present); no-op."
else
  # ---- C.1 — imports ----------------------------------------------------------
  C_IMPORT_OLD="import { chat, isAvailable } from './ai/gateway.ts';"
  C_IMPORT_NEW="import { chat, isAvailable } from './ai/gateway.ts';
// FIX-TK-2-WIRING (Part C): markdown-first per-entity take write + subject/speaker routing.
import { writeTakesToFence, type FenceInputTake } from './takes/fence-write.ts';
import { resolveTakeSubjects, resolveSpeaker } from './takes/route.ts';
import { lookupSourceLocalPath } from './facts/fence-write.ts';
import { buildGazetteer, type Gazetteer } from './by-mention.ts';"

  export C_IMPORT_OLD C_IMPORT_NEW
  perl -0777 -i -pe '
    my $o = $ENV{C_IMPORT_OLD};
    my $n = $ENV{C_IMPORT_NEW};
    s/\Q$o\E/$n/ unless /FIX-TK-2-WIRING/;
  ' "$EXTRACT_FILE"

  # ---- C.1b — add `frontmatter` to PageRow + the eligible-pages SELECT so
  #             resolveSpeaker can read source frontmatter. -------------------
  C_PAGEROW_OLD="  compiled_truth: string;
  updated_at: string | Date;
}"
  C_PAGEROW_NEW="  compiled_truth: string;
  updated_at: string | Date;
  // FIX-TK-2-WIRING: frontmatter is read by resolveSpeaker (source-page speaker).
  frontmatter: Record<string, unknown>;
}"
  export C_PAGEROW_OLD C_PAGEROW_NEW
  perl -0777 -i -pe '
    my $o = $ENV{C_PAGEROW_OLD};
    my $n = $ENV{C_PAGEROW_NEW};
    s/\Q$o\E/$n/ unless /FIX-TK-2-WIRING: frontmatter is read by resolveSpeaker/;
  ' "$EXTRACT_FILE"
  # Landing assertion (C.1b PageRow): the preflight only checks the SUBSTRING
  # 'compiled_truth: string;' (kept short for re-run idempotency), so it can pass
  # while the full 3-line splice anchor moved → this splice silently no-ops.
  grep -qF 'FIX-TK-2-WIRING: frontmatter is read by resolveSpeaker' "$EXTRACT_FILE" || { echo "[gbrain-patch:tk-2] ERROR: [C.1b] PageRow.frontmatter field did not land (3-line anchor moved past the preflight substring). RE-POINT." >&2; exit 1; }

  C_SELECT_OLD="    \`SELECT id, slug, source_id, type, compiled_truth, updated_at"
  C_SELECT_NEW="    \`SELECT id, slug, source_id, type, compiled_truth, COALESCE(frontmatter, '{}'::jsonb) AS frontmatter, updated_at"
  export C_SELECT_OLD C_SELECT_NEW
  perl -0777 -i -pe '
    my $o = $ENV{C_SELECT_OLD};
    my $n = $ENV{C_SELECT_NEW};
    s/\Q$o\E/$n/ unless /COALESCE\(frontmatter/;
  ' "$EXTRACT_FILE"
  # Landing assertion (C.1b SELECT) — THE critical one: the preflight checks only
  # the '...compiled_truth,' prefix, so an upstream column added before 'updated_at'
  # lets preflight pass while this splice silently no-ops → frontmatter is never
  # SELECTed → resolveSpeaker degrades every holder to 'system' (silent, since bun
  # does not typecheck and nothing else greps this).
  grep -qF "COALESCE(frontmatter, '{}'::jsonb) AS frontmatter" "$EXTRACT_FILE" || { echo "[gbrain-patch:tk-2] ERROR: [C.1b] eligible-pages SELECT frontmatter did not land (SELECT anchor moved past the preflight prefix). RE-POINT." >&2; exit 1; }

  # ---- C.2 — replace the per-page push-loop with the per-subject fence loop ---
  # The OLD region is the per-page claims loop (extract-takes-from-pages.ts:201-213):
  #   for (let i = 0; i < claims.length; i++) {
  #     const c = claims[i];
  #     batch.push({ page_id: page.id, row_num: i + 1, claim: c.claim, kind: c.kind,
  #                  holder, weight: c.weight, source: 'cli:takes-bootstrap-from-pages' });
  #   }
  #   if (batch.length >= 200) await flush();
  #
  # We match from the loop opener through the `await flush();` line and replace
  # with: resolve the speaker once per page; per claim resolve subjects; write
  # the take to each subject entity's `## Takes` fence (markdown-first). DB-only
  # batch (drained by the existing flush()) is the fallback for
  # stubGuardBlocked / legacyFallback only. No-subject → origin page.
  #
  # The gazetteer is built ONCE (lazily, first time a source/person page needs
  # the NER fallback) and reused across pages/claims — buildGazetteer is a
  # brain-wide scan, so per-claim builds would be O(pages^2).

  read -r -d '' C_LOOP_NEW <<'CLOOP_EOF' || true
    // FIX-TK-2-WIRING (Part C): markdown-first, per-subject-entity take write.
    // Each claim is routed to the entity it is ABOUT (resolveTakeSubjects) and
    // attributed to the page's speaker (resolveSpeaker), then written to that
    // entity page's `## Takes` fence so it lands in compiled_truth / get_page.
    // No-subject claims stay on the ORIGIN page (page.slug) — no regression vs
    // the prior page_id = page.id behaviour. stubGuardBlocked / legacyFallback
    // takes fall through to the DB-only `batch` (drained by flush()).
    const speaker = await resolveSpeaker(engine, {
      slug: page.slug,
      type: page.type,
      source_id: page.source_id,
      frontmatter: page.frontmatter ?? {},
    });
    const _pageLocalPath = await _resolveLocalPath(page.source_id);
    for (let i = 0; i < claims.length; i++) {
      const c = claims[i];
      if (!_takeGazetteer) {
        try { _takeGazetteer = await buildGazetteer(engine); } catch { _takeGazetteer = undefined; }
      }
      const subjects = await resolveTakeSubjects(
        engine,
        { slug: page.slug, source_id: page.source_id },
        c.claim,
        _takeGazetteer,
      );
      // No resolved subject → keep the take on its origin page (no regression).
      const targets = subjects.length > 0 ? subjects : [page.slug];
      const fenceTake: FenceInputTake = {
        claim: c.claim,
        kind: c.kind,
        holder: speaker || holder,
        weight: c.weight,
        source: `source:${page.slug}`,
      };
      for (const slug of targets) {
        let res;
        try {
          res = await writeTakesToFence(
            engine,
            { sourceId: page.source_id, localPath: _pageLocalPath, slug },
            [fenceTake],
          );
        } catch {
          res = undefined;
        }
        if (!res || res.legacyFallback || res.stubGuardBlocked || res.fenceWriteFailed) {
          // DB-only fallback sink (drained by flush()). row_num is assigned
          // per-page below; the engine's UNIQUE (page_id, row_num) surfaces
          // collisions as failures (caller re-runs) — same posture as before.
          batch.push({
            page_id: page.id,
            row_num: i + 1,
            claim: c.claim,
            kind: c.kind,
            holder: speaker || holder,
            weight: c.weight,
            source: 'cli:takes-bootstrap-from-pages',
          });
        } else {
          claimsExtracted += res.inserted;
        }
      }
    }
    if (batch.length >= 200) await flush();
CLOOP_EOF
  export C_LOOP_NEW

  # Anchor the match on the loop opener through the flush() line. quotemeta the
  # opener; non-greedy through the flush() terminator.
  C_LOOP_OPEN="    for (let i = 0; i < claims.length; i++) {"
  C_LOOP_TERM="    if (batch.length >= 200) await flush();"
  export C_LOOP_OPEN C_LOOP_TERM
  perl -0777 -i -pe '
    my $open = quotemeta($ENV{C_LOOP_OPEN});
    my $term = quotemeta($ENV{C_LOOP_TERM});
    my $new  = $ENV{C_LOOP_NEW};
    s/${open}.*?${term}/$new/s unless /FIX-TK-2-WIRING.*per-subject-entity take write/s;
  ' "$EXTRACT_FILE"
  # Landing assertion (C.2 loop): both loop anchors ARE exact-preflighted, but this
  # is belt-and-suspenders for the rare case where a second 'await flush();' between
  # the anchors shortens the non-greedy match. Grep the loop-unique landed comment
  # (NOT 'writeTakesToFence', which also appears in the C.1 import → false pass).
  grep -qF 'per-subject-entity take write' "$EXTRACT_FILE" || { echo "[gbrain-patch:tk-2] ERROR: [C.2] push-loop replacement did not land (takes would stay DB-only, no entity routing). RE-POINT." >&2; exit 1; }

  # ---- C.3 — declare the per-run gazetteer cache + resolved local_path -------
  # These two locals are referenced by the new loop. We declare them alongside
  # the existing `const batch: TakeBatchInput[] = [];` line so they share the
  # extractTakesFromPages function scope. `_takeLocalPath` is resolved from the
  # engine's source row (the brain's filesystem root); null → fence-write returns
  # legacyFallback → DB-only path (thin-client safe).
  C_DECL_OLD="  const batch: TakeBatchInput[] = [];"
  C_DECL_NEW="  const batch: TakeBatchInput[] = [];
  // FIX-TK-2-WIRING: per-run gazetteer cache (buildGazetteer is a brain-wide
  // scan — build once, reuse across pages/claims) + per-source_id local_path
  // cache. local_path is resolved via the canonical facts helper
  // (lookupSourceLocalPath, facts/fence-write.ts:288); null → fence-write
  // returns legacyFallback → DB-only path (thin-client safe). Pages can span
  // multiple source_ids, so we cache per source_id rather than once per run.
  let _takeGazetteer: Gazetteer | undefined;
  const _takeLocalPathCache = new Map<string, string | null>();
  const _resolveLocalPath = async (sourceId: string): Promise<string | null> => {
    if (_takeLocalPathCache.has(sourceId)) return _takeLocalPathCache.get(sourceId) ?? null;
    let lp: string | null = null;
    try { lp = await lookupSourceLocalPath(engine, sourceId); } catch { lp = null; }
    _takeLocalPathCache.set(sourceId, lp);
    return lp;
  };"

  export C_DECL_OLD C_DECL_NEW
  # Guard on the decl's OWN unique marker (_takeLocalPathCache), NOT _takeGazetteer
  # — the C.2 loop block above already introduced `_takeGazetteer` into the file
  # (slurp mode sees the whole file), so guarding on it would skip this edit.
  perl -0777 -i -pe '
    my $o = $ENV{C_DECL_OLD};
    my $n = $ENV{C_DECL_NEW};
    s/\Q$o\E/$n/ unless /_takeLocalPathCache/;
  ' "$EXTRACT_FILE"

  if ! grep -qF '_takeLocalPathCache' "$EXTRACT_FILE"; then
    echo "[gbrain-patch:tk-2] ERROR: [C.3] gazetteer/local_path decl block did not land (the 'const batch' anchor may have shifted). RE-POINT." >&2
    exit 1
  fi

  if ! grep -qF 'FIX-TK-2-WIRING' "$EXTRACT_FILE"; then
    echo "[gbrain-patch:tk-2] ERROR: [C] wiring did not land in extract-takes-from-pages.ts. RE-POINT." >&2
    exit 1
  fi
  echo "[gbrain-patch:tk-2] [C] ✓ extractor now writes takes to per-subject-entity fences (DB-only fallback retained)."
fi

# ---------------------------------------------------------------------------
# 6. Post-patch verification (re-grep every sentinel + the old code is gone).
# ---------------------------------------------------------------------------
echo "[gbrain-patch:tk-2] post-patch verification..."
FAIL=0

[ -f "$FENCE_WRITE_FILE" ] && grep -qF 'FIX-TK-2' "$FENCE_WRITE_FILE" || { echo "[gbrain-patch:tk-2] ERROR: takes/fence-write.ts sentinel missing." >&2; FAIL=1; }
[ -f "$ROUTE_FILE" ]       && grep -qF 'FIX-TK-2' "$ROUTE_FILE"       || { echo "[gbrain-patch:tk-2] ERROR: takes/route.ts sentinel missing." >&2; FAIL=1; }
grep -qF "'source', 'person', 'company'," "$EXTRACT_FILE" || { echo "[gbrain-patch:tk-2] ERROR: [B] ALLOWED_PAGE_TYPES not widened." >&2; FAIL=1; }
grep -qF 'FIX-TK-2-WIRING' "$EXTRACT_FILE" || { echo "[gbrain-patch:tk-2] ERROR: [C] wiring sentinel missing." >&2; FAIL=1; }
grep -qF 'writeTakesToFence' "$EXTRACT_FILE" || { echo "[gbrain-patch:tk-2] ERROR: [C] writeTakesToFence call missing from extractor." >&2; FAIL=1; }

if [ "$FAIL" = "1" ]; then
  echo "[gbrain-patch:tk-2] ERROR: post-patch verification failed — see errors above." >&2
  exit 1
fi

echo "[gbrain-patch:tk-2] ✓ all sentinels present; takes now route to entity-page fences."
echo "[gbrain-patch:tk-2] done."
