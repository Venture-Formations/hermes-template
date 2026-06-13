#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-schema-pack-resolve-merge.sh   (VF-FIX-SP-MERGE)
#
# WHY THIS EXISTS
#   Upstream #1749 (open, confirmed broken @ 4ee530f): registry.ts resolvePack
#   walks the extends chain ONLY for the depth cap + cache snapshot, then
#   builds the ResolvedPack from the BARE CHILD manifest (buildAliasGraph(
#   manifest) / computeAliasClosureHash(manifest) / the `manifest:` literal
#   all reference the child). Upstream's own comment admits it: "Full
#   extends-merging (child-wins) is the v0.41+ T20 follow-up." So a custom
#   pack `extends: gbrain-base-v2` collapses to its OWN types (e.g. 2) instead
#   of the inherited 15 + additions. Upstream #1838 (open): the bundled lens
#   meta-pack `gbrain-everything` (extends gbrain-investor → base, PLUS
#   borrow_from creator(atom) + engineer(learning)) never composes its
#   borrowed types — borrow_from is a declared-but-uncomposed signal — so
#   `everything` is missing `atom` + `learning`, and a naive borrow walker
#   stack-overflows on a borrowed pack that itself extends/borrows.
#
# WHAT THIS PATCH DOES
#   FULL-FILE REPLACEMENT of src/core/schema-pack/registry.ts with a corrected
#   drop-in keyed to GBRAIN_REF=4ee530f3c545b880cecc47c4f877e0ed014896b4. The
#   drop-in adds composeManifest() — child-wins over BOTH composition axes:
#     • EXTENDS (root→leaf) over ALL mergeable arrays (page_types/link_types/
#       frontmatter_links/enrichable_types/filing_rules keyed-override+union;
#       takes_kinds set-union w/ fact|take|bet|hunch floor; phases set-union;
#       calibration_domains keyed; mapping_rules concat-dedupe w/ *unknown*
#       retype catch-all forced LAST).
#     • BORROW (leaf.borrow_from, declared order) over page_types + link_types
#       ONLY (exactly the two arrays the manifest borrow_from schema carries —
#       {pack, types?, link_types?}; borrow does NOT contribute phases /
#       calibration_domains / filing_rules / takes_kinds — matches the YAML's
#       own "borrow_from borrows types/link_types only" contract). Each
#       borrowed pack is resolved RECURSIVELY to its FULL manifest (its own
#       extends+borrow composed) then FILTERED to entry.types / entry.link_types.
#   PRECEDENCE (specificity): leaf-own > explicit-borrow > extends-inherited
#     (root→leaf, nearer-leaf wins). A borrow is a DELIBERATE pull of one
#     named definition, so it beats the generic extends-inherited same-named
#     type; the leaf's own inline declaration beats everything. For
#     `gbrain-everything` this yields atom = creator's (primitive=concept),
#     resolving the red-team's creator.atom-vs-base.atom collision by rule.
#   It writes the merged taxonomy into resolved.manifest (the field every
#   consumer reads), recomputes alias_graph/alias_closure_hash over the MERGED
#   manifest, keeps identity/manifest_sha8 LEAF-anchored (already true
#   upstream), and re-validates output through the strict Zod schema. A
#   standalone pack (extends:null AND borrow_from empty) short-circuits to the
#   child BY REFERENCE → byte-identical no-op (base/base-v2 sha8 unchanged).
#   The leaf-only ref-eq fast path is gated to that same standalone predicate
#   (sound: leaf==merged) so a parent/borrowed-pack edit can never serve a
#   stale merge in-process. CYCLE/DEPTH SAFE: a SINGLE shared visiting-set
#   (true borrow cycle → throw) + TWO independent budgets — per-path borrow
#   recursion depth (+1 PER BORROW HOP, ≤ EXTENDS_DEPTH_HARD_CAP) AND a shared
#   total-resolutions cap (MERGE_TOTAL_RESOLUTIONS_CAP) — bound the combined
#   extends+borrow graph (kills the #1838 borrow stack-overflow) without
#   counting borrow breadth as extends depth; the extends chain keeps its own
#   leaf-inclusive length cap. FAIL-LOUD HARDENING: a borrow naming a
#   type/link_type absent from the resolved source throws
#   BorrowedTypeNotFoundError, and the MERGED manifest is referentially
#   checked (calibration_domains / mapping_rules / frontmatter_links must
#   resolve) → DanglingReferenceError (the checks strict Zod does NOT do).
#   Borrow entries resolve sequentially in declared order (later-declared wins
#   a key collision) with plain set() merges → cold-run deterministic.
#
# ANCHOR / GUARD STRATEGY
#   PRE-CLOBBER sha256 guard: registry.ts must be the pristine 4ee530f blob
#   (4dafc249…) before overwrite. Mismatch ⇒ upstream changed the file ⇒
#   exit 1 ⇒ Docker build FAILS (old container keeps serving). Re-key the
#   drop-in (UPGRADING_GBRAIN.md → "Re-keying a full-file-replacement patch").
#   Idempotency: marker VF-FIX-SP-MERGE makes a re-run a no-op. Post-write
#   audit re-greps the marker.
#
# gbrain CORE modification — applied at Docker BUILD after the gbrain install,
# baked in, re-applied on every GBRAIN_REF bump. RE-VALIDATE ON EVERY UPGRADE.
# Registry: hermes-workspace/MODIFICATIONS.md.
# ---------------------------------------------------------------------------
set -euo pipefail
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then echo "[sp-merge] ERROR: gbrain src tree not found." >&2; exit 1; fi
echo "[sp-merge] target: $GBRAIN_SRC"
REG="$GBRAIN_SRC/core/schema-pack/registry.ts"
[ -f "$REG" ] || { echo "[sp-merge] ERROR: $REG not found — layout changed. RE-POINT." >&2; exit 1; }
MARKER='VF-FIX-SP-MERGE'
if grep -qF "$MARKER" "$REG"; then echo "[sp-merge] ✓ already applied; no-op."; exit 0; fi
sha_of(){ sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }
REG_VANILLA_SHA="4dafc249eeed095bbadd5adba2d2853b3d74b5ee6a6875ef10543b8fe5a9bcac"
GOT="$(sha_of "$REG")"
if [ "$GOT" != "$REG_VANILLA_SHA" ]; then
  echo "[sp-merge] ERROR: registry.ts drift — NOT the 4ee530f version." >&2
  echo "[sp-merge]   expected $REG_VANILLA_SHA" >&2
  echo "[sp-merge]   got      $GOT" >&2
  echo "[sp-merge]   RE-KEY THIS DROP-IN (UPGRADING_GBRAIN.md → 'Re-keying a full-file-replacement patch')." >&2
  exit 1
fi
echo "[sp-merge] pre-clobber guard OK (registry.ts is pristine 4ee530f)."
# ---- registry.ts (corrected drop-in, carries marker VF-FIX-SP-MERGE) ----
cat > "$REG" <<'VF_PATCH_EOF'
// v0.38 schema pack registry — load, cache, resolve active pack.
//
//                  ┌──────────────────────────────────────────────────────┐
//                  │   loadActivePack lifecycle (per process, v0.40.6.0)  │
//                  └──────────────────────────────────────────────────────┘
//                                       │
//              ┌────────────────────────┼────────────────────────┐
//              ▼                        ▼                        ▼
//       cache miss               cache hit                cache hit + TTL expired
//              │                        │                        │
//       fresh load               STAT_TTL_MS gate         statSync compare every file
//       (resolvePack)             (~10ns fast return)     in the extends chain
//              │                        │                        │
//              │                        │              ┌──────────┴──────────┐
//              │                        │              ▼                     ▼
//              │                        │      every mtime unchanged    any mtime changed
//              │                        │              │                     │
//              │                        │      refresh lastStatMs   invalidate(name) +
//              │                        │      return cached         extends-chain cascade
//              │                        │                                  (codex C6)
//              ▼                        ▼                                   │
//       byName.set(name, entry)   return cached                       fresh load
//
// Pack resolution chain (7 tiers per D13, tier-1 trust-gated):
//   1. Per-call `schema_pack` opt — CLI only (`ctx.remote === false`).
//      Rejected for `ctx.remote === true` (D13 trust boundary).
//   2. `GBRAIN_SCHEMA_PACK` env var
//   3. Per-source DB config key `schema_pack.source.<id>`
//   4. Brain-wide DB config key `schema_pack`
//   5. `gbrain.yml schema:` section
//   6. `~/.gbrain/config.json schema_pack` field
//   7. Default `gbrain-base`
//
// Extends chain semantics (E4):
//   - Depth tracked via BFS during resolve.
//   - Soft warn to stderr at depth > 4.
//   - Hard reject at depth > 8.
//
// v0.40.6.0 cache invariants (codex C6 + D11 + D13):
//   - Cache key is the pack NAME (not identity sha8). Per-name cache entry
//     records the resolved pack PLUS every file path that fed it AND the
//     identities of every parent in the extends chain.
//   - Cache hits go through a stat-TTL gate (default 1000ms via
//     STAT_TTL_MS, env override GBRAIN_PACK_STAT_TTL_MS). Inside the
//     window: hot-path return (~10ns). Outside: statSync each file; if
//     any mtime changed, invalidate by name + cascade to every dependent.
//   - invalidatePackCache(name) walks the reverse extends-graph and
//     evicts every pack that has `name` in its chain. Without the cascade,
//     editing a parent silently leaves children stale (the codex C6 bug).
//   - The PUBLIC `ResolvedPack.identity` field is unchanged
//     (`<name>@<version>+<sha8>`); the composite cache key lives only
//     inside the registry.

import { statSync } from 'node:fs';
import type {
  SchemaPackManifest,
  PackPageType,
  PackLinkType,
  PackMappingRule,
} from './manifest-v1.ts';
import {
  computeManifestSha8,
  packIdentity,
  parseSchemaPackManifest,
} from './manifest-v1.ts';
import { computeAliasClosureHash, buildAliasGraph, type AliasGraph } from './closure.ts';

export const EXTENDS_DEPTH_WARN = 4 as const;
export const EXTENDS_DEPTH_HARD_CAP = 8 as const;
export const STAT_TTL_MS_DEFAULT = 1000 as const;
// VF-FIX-SP-MERGE (adversarial §5b): TWO independent budgets bound the
// combined extends+borrow graph. (1) EXTENDS_DEPTH_HARD_CAP is the per-path
// EXTENDS chain length (unchanged public const) AND, applied separately, the
// per-path BORROW recursion depth (kills the #1838 borrow→borrow ladder).
// Borrow BREADTH is NOT extends depth — a pack borrowing many shallow siblings
// must not blow the extends cap. (2) MERGE_TOTAL_RESOLUTIONS_CAP bounds the
// TOTAL number of resolveComposed() frames for one top-level resolve, catching
// a wide-and-deep graph that no single per-path cap would. Both throw
// ExtendsChainTooDeepError (the wire-stable error class).
export const MERGE_TOTAL_RESOLUTIONS_CAP = 64 as const;

export class ExtendsChainTooDeepError extends Error {
  readonly depth: number;
  readonly chain: string[];
  constructor(depth: number, chain: string[]) {
    super(`pack extends chain depth ${depth} exceeds hard cap ${EXTENDS_DEPTH_HARD_CAP}: ${chain.join(' → ')}`);
    this.name = 'ExtendsChainTooDeepError';
    this.depth = depth;
    this.chain = chain;
  }
}

export class UnknownPackError extends Error {
  readonly name_: string;
  constructor(name_: string) {
    super(`unknown schema pack: ${name_}`);
    this.name = 'UnknownPackError';
    this.name_ = name_;
  }
}

// VF-FIX-SP-MERGE: a borrow_from entry named a type/link_type that, after
// fully resolving the borrowed pack (its own extends+borrow), is NOT present.
// FAIL LOUD (adversarial §4): a silently-dropped borrowed type can leave a
// dangling calibration_domains/mapping_rules reference that strict Zod does
// NOT catch (those arrays carry bare string refs, no existence check), so a
// silent drop would ship a structurally-broken pack. Throwing here turns the
// dangling-ref into a build/load failure with a paste-ready hint instead.
export class BorrowedTypeNotFoundError extends Error {
  readonly borrower: string;
  readonly borrowedPack: string;
  readonly axis: 'types' | 'link_types';
  readonly missing: string[];
  constructor(borrower: string, borrowedPack: string, axis: 'types' | 'link_types', missing: string[]) {
    super(
      `pack "${borrower}" borrow_from {pack: ${borrowedPack}, ${axis}: [...]} ` +
      `names ${axis} absent from the resolved "${borrowedPack}" pack: ${missing.join(', ')}. ` +
      `Fix the borrow_from entry or the borrowed pack's declarations.`,
    );
    this.name = 'BorrowedTypeNotFoundError';
    this.borrower = borrower;
    this.borrowedPack = borrowedPack;
    this.axis = axis;
    this.missing = missing;
  }
}

// VF-FIX-SP-MERGE: the merged manifest carries a dangling cross-reference
// (calibration_domains[].page_types / mapping_rules[].to_type|link_type /
// frontmatter_links[].page_type|link_type) that points at a type/link_type
// NOT in the merged page_types/link_types. The strict Zod schema does NOT
// enforce these (they are bare string[] / string fields — adversarial §3),
// so without this guard a composition that drops/renames a referenced type
// would Zod-pass and surface as a runtime aggregator/migration error. FAIL
// LOUD at compose time over the MERGED manifest instead.
export class DanglingReferenceError extends Error {
  readonly pack: string;
  readonly problems: string[];
  constructor(pack: string, problems: string[]) {
    super(`merged pack "${pack}" has dangling references: ${problems.join('; ')}`);
    this.name = 'DanglingReferenceError';
    this.pack = pack;
    this.problems = problems;
  }
}

export interface ResolvedPack {
  manifest: SchemaPackManifest;
  identity: string;        // `<name>@<version>+<sha8>` (child only — wire-stable)
  manifest_sha8: string;
  alias_closure_hash: string;
  alias_graph: AliasGraph;
}

export interface ResolutionInput {
  perCall?: string;
  remote: boolean;
  perSourceDb?: ReadonlyMap<string, string>;
  sourceId?: string;
  envVar?: string;
  dbConfig?: string;
  gbrainYml?: string;
  homeConfig?: string;
}

export interface ResolutionResult {
  pack_name: string;
  source: 'per-call' | 'env' | 'per-source-db' | 'db-config' | 'gbrain-yml' | 'home-config' | 'default';
}

export function resolveActivePackName(input: ResolutionInput): ResolutionResult {
  if (input.perCall && input.remote === false) {
    return { pack_name: input.perCall, source: 'per-call' };
  }
  if (input.envVar) return { pack_name: input.envVar, source: 'env' };
  if (input.sourceId && input.perSourceDb?.has(input.sourceId)) {
    return { pack_name: input.perSourceDb.get(input.sourceId)!, source: 'per-source-db' };
  }
  if (input.dbConfig) return { pack_name: input.dbConfig, source: 'db-config' };
  if (input.gbrainYml) return { pack_name: input.gbrainYml, source: 'gbrain-yml' };
  if (input.homeConfig) return { pack_name: input.homeConfig, source: 'home-config' };
  return { pack_name: 'gbrain-base', source: 'default' };
}

/**
 * Per-name cache entry. Tracks the resolved pack PLUS the file-stat
 * snapshot every file in the extends chain fed at resolve time. The
 * stat snapshot is what the cross-process stat-TTL gate compares
 * against on each loadActivePack call.
 */
interface CacheEntry {
  resolved: ResolvedPack;
  /** Names that fed this entry (this pack + every parent transitively). */
  chain: ReadonlyArray<string>;
  /** Stat snapshot per file at resolve time. */
  files: ReadonlyArray<{ name: string; path: string; mtimeMs: number }>;
  /** Last time we stat()'d the files. Date.now() ms. */
  lastStatMs: number;
}

const _byName = new Map<string, CacheEntry>();

/** Test seam — clears the in-process resolver cache. */
export function _resetPackCacheForTests(): void {
  _byName.clear();
}

/**
 * Resolve the effective STAT_TTL_MS, honoring the
 * `GBRAIN_PACK_STAT_TTL_MS` env override. Invalid values fall back to
 * the default with no warning (this is a power-user knob).
 */
function resolveStatTtlMs(): number {
  const raw = process.env.GBRAIN_PACK_STAT_TTL_MS;
  if (!raw) return STAT_TTL_MS_DEFAULT;
  const parsed = Number.parseInt(raw, 10);
  if (Number.isFinite(parsed) && parsed >= 0) return parsed;
  return STAT_TTL_MS_DEFAULT;
}

/**
 * Cheap statSync that returns Infinity on error so callers treat
 * disappearing files as "changed" (forcing reload).
 */
function safeMtimeMs(path: string): number {
  try {
    return statSync(path).mtimeMs;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

/**
 * Check whether a cached entry's file snapshot is still fresh on disk.
 * Returns true when EVERY file's mtime matches the snapshot.
 */
function snapshotMatches(files: ReadonlyArray<{ path: string; mtimeMs: number }>): boolean {
  for (const f of files) {
    if (safeMtimeMs(f.path) !== f.mtimeMs) return false;
  }
  return true;
}

/**
 * Walk the reverse extends-graph: every cached entry whose `chain`
 * contains `name`. The set is unbounded in principle but bounded in
 * practice by EXTENDS_DEPTH_HARD_CAP × installed packs (typically <50).
 */
function findDependents(name: string): string[] {
  const out: string[] = [];
  for (const [cachedName, entry] of _byName) {
    if (entry.chain.includes(name)) out.push(cachedName);
  }
  return out;
}

/**
 * Invalidate the cache for a pack name AND every pack that extends it
 * (transitive — the codex C6 fix). When called with no argument,
 * invalidates everything.
 *
 * Called automatically by `withMutation` (Phase 2) after every
 * successful pack mutation; also exposed via `gbrain schema reload`.
 */
export function invalidatePackCache(name?: string): { invalidated: string[] } {
  if (name === undefined) {
    const all = [..._byName.keys()];
    _byName.clear();
    return { invalidated: all };
  }
  const dependents = findDependents(name);
  // The pack itself + all dependents.
  const toEvict = Array.from(new Set([name, ...dependents]));
  for (const n of toEvict) _byName.delete(n);
  return { invalidated: toEvict };
}

/** Test-only access for assertions on the cache shape. */
export function _cacheSizeForTests(): number {
  return _byName.size;
}

/** Test-only access for assertions on which names are cached. */
export function _cacheNamesForTests(): string[] {
  return [..._byName.keys()];
}

// ───────────────────────────────────────────────────────────────────────
// VF-FIX-SP-MERGE (#1749 + #1838) — full schema composition (child-wins)
// over BOTH the extends chain AND borrow_from.
//
// SCOPE (see hermes MODIFICATIONS.md): the operator wants the schema to
// EVOLVE along both axes — `extends: gbrain-base-v2` + own types (the
// custom-pack path) AND the bundled lens meta-packs (`gbrain-everything`
// extends gbrain-investor → base, borrow_from creator(atom) +
// engineer(learning)). Both now resolve to the correct full union.
//
// TWO AXES, ONE PRECEDENCE LADDER (specificity, low→high):
//   1. extends-inherited  — root → … → parent (nearer-leaf wins among them)
//   2. explicit-borrow    — leaf.borrow_from, declared order (a deliberate
//                           pull of a NAMED def beats generic inheritance)
//   3. leaf-own           — the leaf's own inline declarations beat all
// Realized by ordering the merge layers [root…parent, …borrowed, leaf] and
// relying on mergeKeyed's "later layer wins by key, Map keeps first-insert
// position". For gbrain-everything this gives atom = creator's
// (primitive=concept) — the red-team's creator.atom-vs-base.atom collision
// is decided by RULE, not left ambiguous.
//
// WHICH ARRAYS EACH AXIS FEEDS:
//   • extends feeds ALL mergeable arrays (page_types/link_types/
//     frontmatter_links/enrichable_types/filing_rules/takes_kinds/phases/
//     calibration_domains/mapping_rules).
//   • borrow feeds ONLY page_types + link_types — exactly the two the
//     manifest borrow_from schema carries ({pack, types?, link_types?}).
//     borrow does NOT contribute phases / calibration_domains / filing_rules
//     / takes_kinds (the lens YAMLs re-declare those explicitly by design;
//     "borrow_from borrows types/link_types only" — gbrain-everything.yaml).
//
// BORROW RESOLUTION: each borrow entry's pack is resolved RECURSIVELY to its
// FULL manifest (its own extends+borrow composed) via the same loadByName
// dependency, then FILTERED to entry.types (page_types) / entry.link_types.
// A borrowed pack may itself extend/borrow; a SINGLE shared visiting-set +
// depth budget is threaded across the extends walk AND every borrow recursion
// so a cycle or runaway depth throws ExtendsChainTooDeepError instead of
// overflowing the stack (#1838). Borrow entries resolve SEQUENTIALLY in
// declared order; the union is a plain set()/Map merge → cold-run
// deterministic.
//
// PRECEDENCE within extends: root → … → parent → LEAF; later layer wins by
// key. Absence-preserving for optional arrays (phases / calibration_domains /
// mapping_rules have no Zod default) so a merged standalone pack hashes
// byte-identically to itself. takes_kinds keeps the fact/take/bet/hunch
// floor via set-union. mapping_rules: concat-dedupe with the *unknown*
// retype catch-all forced LAST. Output is re-validated through the strict
// Zod schema. Determinism: canonicalJSONStringify preserves ARRAY order,
// so every union appends in fixed precedence order with in-place keyed
// override (Map keeps first-insert position) → reproducible run to run.

const TAKES_KINDS_FLOOR = ['fact', 'take', 'bet', 'hunch'] as const;
const UNKNOWN_RETYPE_SENTINEL = '*unknown*';

/** Keyed union over ordered layers (low→high). Later key wins, IN PLACE. */
function mergeKeyed<T>(layers: ReadonlyArray<ReadonlyArray<T>>, keyOf: (t: T) => string): T[] {
  const m = new Map<string, T>();
  for (const layer of layers) for (const item of layer) m.set(keyOf(item), item);
  return [...m.values()];
}

/** Absence-preserving keyed union: undefined iff no layer declared it. */
function mergeKeyedOptional<T>(
  layers: ReadonlyArray<ReadonlyArray<T> | undefined>,
  keyOf: (t: T) => string,
): T[] | undefined {
  if (layers.every(l => l === undefined)) return undefined;
  return mergeKeyed(layers.filter((l): l is ReadonlyArray<T> => l !== undefined), keyOf);
}

/** Set-union of strings with a guaranteed floor prefix. */
function mergeStringsWithFloor(
  layers: ReadonlyArray<ReadonlyArray<string>>,
  floor: ReadonlyArray<string>,
): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const f of floor) if (!seen.has(f)) { seen.add(f); out.push(f); }
  for (const layer of layers) for (const s of layer) if (!seen.has(s)) { seen.add(s); out.push(s); }
  return out;
}

/** Absence-preserving set-union of optional string arrays (phases). */
function mergeOptionalStrings(
  layers: ReadonlyArray<ReadonlyArray<string> | undefined>,
): string[] | undefined {
  if (layers.every(l => l === undefined)) return undefined;
  const seen = new Set<string>();
  const out: string[] = [];
  for (const layer of layers) { if (!layer) continue; for (const s of layer) if (!seen.has(s)) { seen.add(s); out.push(s); } }
  return out;
}

/** mapping_rules: concat-dedupe (canonical key) with *unknown* catch-all last. */
function mergeMappingRules(
  layers: ReadonlyArray<ReadonlyArray<PackMappingRule> | undefined>,
): PackMappingRule[] | undefined {
  if (layers.every(l => l === undefined)) return undefined;
  const seen = new Set<string>();
  const specific: PackMappingRule[] = [];
  const catchAll: PackMappingRule[] = [];
  for (const layer of layers) {
    if (!layer) continue;
    for (const rule of layer) {
      const key = canonicalKey(rule);
      if (seen.has(key)) continue;
      seen.add(key);
      const isUnknownRetype =
        (rule as { kind?: string }).kind === 'retype' &&
        (rule as { from_type?: string }).from_type === UNKNOWN_RETYPE_SENTINEL;
      (isUnknownRetype ? catchAll : specific).push(rule);
    }
  }
  const lastCatchAll = catchAll.length > 0 ? [catchAll[catchAll.length - 1]] : [];
  return [...specific, ...lastCatchAll];
}

/** Order-insensitive structural key (sorts object keys) for dedupe. */
function canonicalKey(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(canonicalKey).join(',') + ']';
  const obj = value as Record<string, unknown>;
  return '{' + Object.keys(obj).sort().map(k => JSON.stringify(k) + ':' + canonicalKey(obj[k])).join(',') + '}';
}

/**
 * A borrowed contribution: page_types / link_types pulled (already FILTERED
 * to the borrow entry's `types` / `link_types`) from ONE recursively resolved
 * borrowed pack. Borrow feeds these two arrays ONLY (manifest borrow_from
 * schema = {pack, types?, link_types?}). Declared-order list = precedence
 * among borrows: later-declared wins a key collision, all < leaf-own.
 */
export interface BorrowedLayer {
  page_types: ReadonlyArray<PackPageType>;
  link_types: ReadonlyArray<PackLinkType>;
}

/**
 * Compose an extends chain (leaf-first) PLUS borrowed layers (declared order)
 * into one merged manifest. Returns the leaf BY REFERENCE when there is a
 * single standalone pack AND nothing borrowed → guarantees the base/base-v2
 * no-op invariant byte-for-byte.
 *
 * PRECEDENCE (low→high): extends-inherited (root→parent) < explicit-borrow <
 * leaf-own. Only page_types + link_types see the borrow layer; every other
 * array is composed from the extends chain alone.
 */
export function composeManifest(
  chainLeafFirst: ReadonlyArray<SchemaPackManifest>,
  borrowed: ReadonlyArray<BorrowedLayer> = [],
): SchemaPackManifest {
  if (chainLeafFirst.length <= 1 && borrowed.length === 0) {
    return chainLeafFirst[0]; // no-op: leaf == merged (standalone, no borrow)
  }

  const leaf = chainLeafFirst[0];
  const rootToLeaf = [...chainLeafFirst].reverse();           // root … parent, leaf
  const rootToParent = rootToLeaf.slice(0, -1);               // root … parent (NO leaf)
  const borrowedPageLayers = borrowed.map(b => b.page_types);
  const borrowedLinkLayers = borrowed.map(b => b.link_types);

  // page_types / link_types get the FULL precedence ladder (low→high):
  // extends-inherited (root→parent) < explicit-borrow (declared order) <
  // leaf-own. mergeKeyed = later layer wins by key, first-insert position kept.
  const page_types = mergeKeyed<PackPageType>(
    [...rootToParent.map(m => m.page_types), ...borrowedPageLayers, leaf.page_types],
    pt => pt.name,
  );
  const link_types = mergeKeyed<PackLinkType>(
    [...rootToParent.map(m => m.link_types), ...borrowedLinkLayers, leaf.link_types],
    lt => lt.name,
  );

  // Every other array: extends chain ONLY (root→leaf, leaf wins). Borrow's
  // schema carries only types/link_types, so it contributes nothing here.
  const frontmatter_links = mergeKeyed(
    rootToLeaf.map(m => m.frontmatter_links),
    (fl: { page_type: string; link_type: string }) => `${fl.page_type} ${fl.link_type}`,
  );
  const enrichable_types = mergeKeyed(
    rootToLeaf.map(m => m.enrichable_types),
    (e: { type: string }) => e.type,
  );
  const filing_rules = mergeKeyed(
    rootToLeaf.map(m => m.filing_rules),
    (r: { kind: string }) => r.kind,
  );
  const takes_kinds = mergeStringsWithFloor(rootToLeaf.map(m => m.takes_kinds), TAKES_KINDS_FLOOR);
  const phases = mergeOptionalStrings(rootToLeaf.map(m => m.phases));
  const calibration_domains = mergeKeyedOptional(
    rootToLeaf.map(m => m.calibration_domains),
    (d: { name: string }) => d.name,
  );
  const mapping_rules = mergeMappingRules(rootToLeaf.map(m => m.mapping_rules));

  // Assemble: scalar/identity metadata + extends/borrow_from/migration_from
  // are LEAF-only (wire/identity fields). Absence-preserving optionals are
  // omitted entirely when undefined so re-validation + the canonical hash
  // match a standalone pack. Only schema-legal keys (the schema is .strict()).
  const out: SchemaPackManifest = {
    api_version: leaf.api_version,
    name: leaf.name,
    version: leaf.version,
    description: leaf.description,
    ...(leaf.author !== undefined ? { author: leaf.author } : {}),
    ...(leaf.license !== undefined ? { license: leaf.license } : {}),
    ...(leaf.homepage !== undefined ? { homepage: leaf.homepage } : {}),
    ...(leaf.gbrain_min_version !== undefined ? { gbrain_min_version: leaf.gbrain_min_version } : {}),
    extends: leaf.extends,
    borrow_from: leaf.borrow_from,
    page_types,
    link_types,
    frontmatter_links,
    takes_kinds,
    enrichable_types,
    filing_rules,
    ...(phases !== undefined ? { phases } : {}),
    ...(calibration_domains !== undefined ? { calibration_domains } : {}),
    ...(leaf.migration_from !== undefined ? { migration_from: leaf.migration_from } : {}),
    ...(mapping_rules !== undefined ? { mapping_rules } : {}),
  } as SchemaPackManifest;

  // Re-validate through the strict schema (catches an illegal override;
  // idempotent over an already-valid object).
  const validated = parseSchemaPackManifest(out, { path: `${leaf.name} (merged)` });

  // FAIL LOUD on dangling cross-references that Zod does NOT enforce
  // (adversarial §3). Runs over the MERGED manifest so a composition that
  // dropped a referenced type (e.g. an aggressive borrow override) is caught
  // here, not at runtime. A standalone pack hits the by-ref short-circuit
  // above and never reaches this line, so the base/base-v2 no-op is untouched.
  assertNoDanglingReferences(validated);
  return validated;
}

/**
 * Port of the registry's documented-but-uncodified referential post-checks
 * (manifest-v1.ts: "Pack-load validation (registry)") applied to the MERGED
 * manifest. Throws DanglingReferenceError listing EVERY problem found.
 *   • calibration_domains[].page_types  → must exist in page_types
 *   • mapping_rules retype.to_type      → must exist in page_types
 *     (the `*unknown*` catch-all from_type is exempt — it is a sentinel)
 *   • mapping_rules page_to_link.link_type → must exist in link_types
 *   • frontmatter_links[].page_type / .link_type → must exist
 */
function assertNoDanglingReferences(m: SchemaPackManifest): void {
  const pageNames = new Set(m.page_types.map(p => p.name));
  const linkNames = new Set(m.link_types.map(l => l.name));
  const problems: string[] = [];
  for (const d of m.calibration_domains ?? []) {
    for (const t of d.page_types) {
      if (!pageNames.has(t)) problems.push(`calibration_domain "${d.name}" references missing page_type "${t}"`);
    }
  }
  for (const r of m.mapping_rules ?? []) {
    if ((r as { kind: string }).kind === 'retype') {
      const rr = r as { from_type: string; to_type: string };
      if (rr.from_type !== UNKNOWN_RETYPE_SENTINEL && !pageNames.has(rr.to_type)) {
        problems.push(`mapping_rule retype references missing to_type "${rr.to_type}"`);
      }
    } else if ((r as { kind: string }).kind === 'page_to_link') {
      const pr = r as { link_type: string };
      if (!linkNames.has(pr.link_type)) {
        problems.push(`mapping_rule page_to_link references missing link_type "${pr.link_type}"`);
      }
    }
  }
  for (const fl of m.frontmatter_links) {
    if (!pageNames.has(fl.page_type)) problems.push(`frontmatter_link references missing page_type "${fl.page_type}"`);
    if (!linkNames.has(fl.link_type)) problems.push(`frontmatter_link references missing link_type "${fl.link_type}"`);
  }
  if (problems.length > 0) throw new DanglingReferenceError(m.name, problems);
}

/**
 * Filter a borrowed pack's FULLY-RESOLVED manifest down to the page_types /
 * link_types the borrow entry names. An undefined selector means "borrow
 * none of that array" (the entry opted into the OTHER axis only). Resolution
 * is over the FULL manifest, so a type the borrowed pack itself inherited via
 * its own extends/borrow is borrowable too.
 *
 * FAIL LOUD (adversarial §4): a NAMED type/link_type that is absent from the
 * resolved borrowed pack throws BorrowedTypeNotFoundError. A silent drop would
 * leave the borrower's own calibration_domains/mapping_rules referencing a
 * type that never arrived — a dangling ref strict Zod does NOT catch (§3).
 * This is consistent with the patch's fail-loud convention (mismatch ⇒ build
 * fails, old container keeps serving). NOTE: the four bundled lens packs all
 * name only types their source pack really declares, so this guard NEVER
 * trips for the shipped set — it is defense against a future upstream rename.
 */
function filterBorrowed(
  borrowerName: string,
  borrowedPackName: string,
  resolvedBorrow: SchemaPackManifest,
  entry: { types?: ReadonlyArray<string>; link_types?: ReadonlyArray<string> },
): BorrowedLayer {
  const havePages = new Set(resolvedBorrow.page_types.map(pt => pt.name));
  const haveLinks = new Set(resolvedBorrow.link_types.map(lt => lt.name));
  if (entry.types) {
    const missing = entry.types.filter(t => !havePages.has(t));
    if (missing.length > 0) throw new BorrowedTypeNotFoundError(borrowerName, borrowedPackName, 'types', missing);
  }
  if (entry.link_types) {
    const missing = entry.link_types.filter(t => !haveLinks.has(t));
    if (missing.length > 0) throw new BorrowedTypeNotFoundError(borrowerName, borrowedPackName, 'link_types', missing);
  }
  const wantTypes = entry.types ? new Set(entry.types) : null;
  const wantLinks = entry.link_types ? new Set(entry.link_types) : null;
  return {
    page_types: wantTypes ? resolvedBorrow.page_types.filter(pt => wantTypes.has(pt.name)) : [],
    link_types: wantLinks ? resolvedBorrow.link_types.filter(lt => wantLinks.has(lt.name)) : [],
  };
}

/**
 * Recursively resolve a manifest to its FULLY-COMPOSED form (extends chain
 * merged AND borrow_from composed), threading a SINGLE shared `visiting` set
 * + `depth` budget across BOTH axes. This is the cycle/overflow guard for
 * #1838.
 *
 * VISITING-SET SEMANTICS (subtle — the correctness hinge): `visiting` tracks
 * the active BORROW recursion path ONLY — the pack names currently being
 * composed up the call stack. It does NOT contain extends-parents. Why:
 *   • extends-parents are merged FLAT by a local walk; we never recurse
 *     resolveComposed() into them (borrow_from is a LEAF-only field — an
 *     extends-parent's own borrow_from is not composed), so they can't begin
 *     a cycle. Their LOCAL cycle/dup is caught by `localChainNames`.
 *   • a borrowed pack legitimately re-extending an ancestor of its borrower
 *     (e.g. `gbrain-everything` extends → base, then BORROWS `gbrain-creator`
 *     which itself extends base) is NORMAL, not a cycle. If extends-parents
 *     poisoned `visiting`, that sibling-shared-ancestor case would falsely
 *     throw. So only the borrow-path pack name is marked.
 * The TRUE cycle we prevent: a pack whose borrow graph (transitively) borrows
 * itself — caught by the `visiting.has(manifest.name)` re-entry check.
 *
 * TWO BUDGETS (adversarial §5b), NOT one conflated counter:
 *   • `borrowDepth` — the BORROW recursion depth ONLY (incremented by exactly
 *     1 per recursive borrow hop, NOT by extends-chain length). Bounded by
 *     EXTENDS_DEPTH_HARD_CAP → a borrow→borrow→borrow ladder (#1838) throws,
 *     while a pack that borrows many SHALLOW siblings does not falsely trip it.
 *   • `budget.left` — a shared, monotonically-decrementing TOTAL-resolutions
 *     counter (starts at MERGE_TOTAL_RESOLUTIONS_CAP) spent once per
 *     resolveComposed() frame across the whole graph → bounds wide-AND-deep
 *     graphs that no single per-path cap catches.
 * The EXTENDS chain length inside each frame keeps its OWN local cap
 * (EXTENDS_DEPTH_HARD_CAP over `extDepth`), unchanged from upstream semantics.
 *
 * `deps` accumulates every name that fed the composition (extends parents +
 * borrowed packs, transitively) so the caller can record them in the cache
 * entry's `chain` → invalidatePackCache(depName) cascades to dependents
 * (including on a borrowed-pack edit).
 *
 * Determinism: the extends chain is walked leaf→root in declared order; each
 * borrow entry is resolved SEQUENTIALLY in declared order; composeManifest
 * applies a fixed precedence ladder. No Promise.all / no Set-iteration-order
 * dependence in the merge → identical bytes on every cold run.
 */
async function resolveComposed(
  manifest: SchemaPackManifest,
  loadByName: (name: string) => Promise<SchemaPackManifest>,
  ctx: {
    visiting: Set<string>;
    borrowDepth: number;          // BORROW recursion depth only (§5b)
    budget: { left: number };     // shared TOTAL-resolutions counter (§5b)
    deps: Set<string>;
    onDepthWarn?: (depth: number, chain: string[]) => void;
  },
): Promise<SchemaPackManifest> {
  // Budget 2: total resolveComposed frames across the whole graph.
  if (ctx.budget.left <= 0) {
    throw new ExtendsChainTooDeepError(MERGE_TOTAL_RESOLUTIONS_CAP, [...ctx.visiting, manifest.name]);
  }
  ctx.budget.left--;
  // Budget 1: per-path borrow recursion depth.
  if (ctx.borrowDepth > EXTENDS_DEPTH_HARD_CAP) {
    throw new ExtendsChainTooDeepError(ctx.borrowDepth, [...ctx.visiting, manifest.name]);
  }
  if (ctx.visiting.has(manifest.name)) {
    // True borrow cycle: this pack is already being composed up the stack.
    throw new ExtendsChainTooDeepError(ctx.visiting.size + 1, [...ctx.visiting, manifest.name]);
  }
  // Mark ONLY this pack on the shared borrow-path set; remove it on exit so
  // sibling borrow branches that share this pack as a (non-active) ancestor
  // are not mis-flagged. Extends-parents are NOT added here (see doc above).
  ctx.visiting.add(manifest.name);
  try {
    // 1. Walk THIS manifest's own extends chain (leaf-first), enforcing the
    //    shared depth budget. Parents are tracked LOCALLY only.
    const chainManifests: SchemaPackManifest[] = [manifest];
    const localChainNames: string[] = [manifest.name];
    let cursor: SchemaPackManifest | null = manifest;
    // Local extends-chain depth for THIS frame, LEAF-INCLUSIVE (the leaf
    // itself is depth 1) to match upstream's chain-length convention: a
    // 5-pack chain reports depth 5, fires the soft-warn at depth > WARN(4),
    // throws at depth > HARD_CAP(8). Independent of borrowDepth — §5b: borrow
    // breadth is not extends depth. Resets per frame.
    let extDepth = 1;
    while (cursor?.extends) {
      const parentName = cursor.extends;
      if (localChainNames.includes(parentName)) {
        // Local extends cycle (A extends B extends A).
        throw new ExtendsChainTooDeepError(extDepth + 1, [...localChainNames, parentName]);
      }
      extDepth++;
      if (extDepth > EXTENDS_DEPTH_HARD_CAP) {
        throw new ExtendsChainTooDeepError(extDepth, [...localChainNames, parentName]);
      }
      if (extDepth > EXTENDS_DEPTH_WARN) {
        ctx.onDepthWarn?.(extDepth, [...localChainNames, parentName]);
      }
      ctx.deps.add(parentName);
      localChainNames.push(parentName);
      cursor = await loadByName(parentName);
      chainManifests.push(cursor);
    }

    // 2. Resolve borrow_from (LEAF-only field — declared order). Each borrowed
    //    pack is resolved RECURSIVELY (its own extends+borrow composed) under
    //    the SAME shared visiting-set + an incremented depth budget, then
    //    filtered to the entry's types/link_types.
    const borrowedLayers: BorrowedLayer[] = [];
    for (const entry of manifest.borrow_from ?? []) {
      ctx.deps.add(entry.pack);
      const borrowedManifest = await loadByName(entry.pack);
      const resolvedBorrow = await resolveComposed(borrowedManifest, loadByName, {
        visiting: ctx.visiting,
        borrowDepth: ctx.borrowDepth + 1,   // §5b: +1 PER BORROW HOP only
        budget: ctx.budget,                 // §5b: shared total-resolutions counter
        deps: ctx.deps,
        onDepthWarn: ctx.onDepthWarn,
      });
      borrowedLayers.push(filterBorrowed(manifest.name, entry.pack, resolvedBorrow, entry));
    }

    // 3. Compose: extends chain + borrowed layers, with the precedence ladder
    //    leaf-own > explicit-borrow > extends-inherited.
    return composeManifest(chainManifests, borrowedLayers);
  } finally {
    // Leave the shared borrow-path set as we found it (remove only ourselves).
    ctx.visiting.delete(manifest.name);
  }
}

/**
 * Resolve + cache a manifest. Loads parent packs via the `loadByName`
 * dependency, tracks extends-chain depth, applies the E4 cap.
 *
 * v0.40.6.0: cache is name-keyed and tracks file-stat snapshots so the
 * stat-TTL gate (inside `loadActivePack`) can detect cross-process
 * mutations without re-reading the bytes.
 *
 * `loadByPath` is the disk path resolver for each name in the extends
 * chain (used for the file-stat snapshot). Optional — when omitted, the
 * snapshot is empty and stat-TTL becomes a no-op for this entry (used
 * by tests that drive synthetic manifests with no disk backing).
 */
export async function resolvePack(
  manifest: SchemaPackManifest,
  loadByName: (name: string) => Promise<SchemaPackManifest>,
  opts: {
    onDepthWarn?: (depth: number, chain: string[]) => void;
    loadByPath?: (name: string) => string | null;
  } = {},
): Promise<ResolvedPack> {
  const sha8 = await computeManifestSha8(manifest);
  const id = packIdentity(manifest, sha8);

  // Reference-equality fast path: if a previous resolvePack(manifest, ...)
  // produced the SAME identity, return the cached resolved object. This
  // preserves the v0.38 contract that two calls with the same manifest
  // bytes return the same JS object reference.
  //
  // VF-FIX-SP-MERGE: the leaf-only identity key is SOUND ONLY for a
  // standalone pack (extends:null AND no borrow_from), where leaf == merged.
  // For a pack WITH an extends chain OR borrow_from, the leaf identity does
  // not capture parent/borrowed-pack edits, so we must NOT short-circuit
  // here — we fall through to re-resolve and let loadActivePack's stat-TTL
  // gate (tryCachedPack) handle freshness. This removes the stale-dependency
  // trap by construction without a resolved_sha8.
  const isStandalone = manifest.extends == null && (manifest.borrow_from?.length ?? 0) === 0;
  const existing = _byName.get(manifest.name);
  if (isStandalone && existing && existing.resolved.identity === id) {
    return existing.resolved;
  }

  // VF-FIX-SP-MERGE (#1749 + #1838) — full child-wins composition over BOTH
  // the extends chain (root → leaf) AND borrow_from. resolveComposed threads
  // a SINGLE shared visiting-set + depth budget across both axes (cycle/
  // overflow guard) and resolves each borrowed pack RECURSIVELY to its full
  // manifest before filtering to the borrow entry's types/link_types. `deps`
  // collects every name that fed the merge (extends parents + borrowed packs,
  // transitively) so the cache entry's `chain` lets invalidatePackCache(dep)
  // cascade to this pack (codex C6 — now extended to borrowed deps too).
  //
  // Closure is computed over the MERGED manifest so a pack that
  // `extends: gbrain-base-v2` inherits base-v2's full page_types + alias
  // closure PLUS its additions, and `gbrain-everything` gets creator.atom +
  // engineer.learning via borrow. For a standalone pack (extends:null AND
  // no borrow) resolveComposed → composeManifest returns the child BY
  // REFERENCE, so computeManifestSha8(merged) === computeManifestSha8(child)
  // and the base/base-v2 no-op invariant holds byte-for-byte.
  const deps = new Set<string>();
  const merged = await resolveComposed(manifest, loadByName, {
    visiting: new Set<string>(),
    borrowDepth: 0,
    budget: { left: MERGE_TOTAL_RESOLUTIONS_CAP },
    deps,
    onDepthWarn: opts.onDepthWarn,
  });
  // Cache chain = self + every transitive dependency (extends + borrow).
  const chain: string[] = [manifest.name, ...deps];
  const alias_graph = buildAliasGraph(merged);
  const alias_closure_hash = await computeAliasClosureHash(merged);

  const resolved: ResolvedPack = {
    manifest: merged,    // ← consumed field carries the merged taxonomy
    identity: id,        // ← leaf-only, wire-stable (computed from child)
    manifest_sha8: sha8, // ← leaf-only
    alias_closure_hash,
    alias_graph,
  };

  // Capture file-stat snapshot for the stat-TTL gate. Skip names that
  // the locator can't resolve (synthetic manifests in tests).
  const files: Array<{ name: string; path: string; mtimeMs: number }> = [];
  if (opts.loadByPath) {
    for (const n of chain) {
      const path = opts.loadByPath(n);
      if (path === null) continue;
      files.push({ name: n, path, mtimeMs: safeMtimeMs(path) });
    }
  }

  _byName.set(manifest.name, {
    resolved,
    chain: [...chain],
    files,
    lastStatMs: Date.now(),
  });
  return resolved;
}

/**
 * Try to return a cached resolved pack for `name` without re-reading the
 * manifest from disk. Returns null on cache miss OR when the stat-TTL
 * gate detects a file change (which triggers eviction + cascade).
 *
 * The TTL gate keeps the hot path cheap: most calls inside the 1-second
 * window return immediately (~10ns) without statting. Outside the
 * window: one statSync per file in the extends chain (~50µs per file).
 * Worst-case latency for a daemon picking up an operator's mutation:
 * 1 second.
 */
export function tryCachedPack(name: string): ResolvedPack | null {
  const entry = _byName.get(name);
  if (!entry) return null;
  const ttl = resolveStatTtlMs();
  const ageMs = Date.now() - entry.lastStatMs;
  if (ageMs < ttl) return entry.resolved;
  // TTL expired: stat all files. If any changed, cascade-invalidate.
  if (!snapshotMatches(entry.files)) {
    invalidatePackCache(name);
    return null;
  }
  // Snapshot still fresh: refresh lastStatMs so the next hot-path return
  // is cheap again.
  _byName.set(name, { ...entry, lastStatMs: Date.now() });
  return entry.resolved;
}
VF_PATCH_EOF
grep -qF 'VF-FIX-SP-MERGE' "$REG" || { echo "[sp-merge] ERROR: marker absent post-write." >&2; exit 1; }
echo "[sp-merge] ✓ patch applied (registry.ts extends-merge)."
