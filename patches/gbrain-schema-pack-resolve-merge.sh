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
# WHAT THIS PATCH DOES  (C+B refactor: ANCHOR-SPLICE, not full-file replace)
#   The inheritance engine lives ENTIRELY in resolvePack: the
#   config-activation path (DB/tier-6 cfg.schema_pack → defaultPackLocator →
#   resolvePack) exercises the SAME merge as `schema use`. So the ONE change
#   gbrain actually needs is to feed resolvePack's downstream consumers the
#   MERGED manifest instead of the bare child. This patch does exactly that
#   with a minimal, fail-loud anchor-splice (the YAML #1750 + SSOT #1574/#1726
#   full-file patches were DROPPED — see the C+B audit / UPGRADING_GBRAIN.md):
#
#   (1) IMPORT SPLICE — widen the two manifest-v1 imports so the appended block
#       can reference PackPageType/PackLinkType/PackMappingRule (types) and
#       parseSchemaPackManifest (value).
#   (2) INLINE SPLICE in resolvePack, anchored on the self-documenting
#       "// Full extends-merging (child-wins) is the v0.41+ T20 follow-up."
#       comment block (when upstream lands T20 the comment changes → the anchor
#       preflight below fails LOUD → we delete this patch):
#         • INSERT `const merged = (manifest.extends || (manifest.borrow_from
#           && manifest.borrow_from.length)) ? mergeExtendsChain(manifest,
#           loadByName, opts) : manifest;` just before the alias-graph build.
#         • SWAP the 3 consumers child→merged: buildAliasGraph(manifest)→(merged),
#           computeAliasClosureHash(manifest)→(merged), and the ResolvedPack
#           literal field `manifest,` → `manifest: merged,`.
#   (3) EOF APPEND (additive, marker VF-FIX-SP-MERGE) — mergeExtendsChain (an
#       async wrapper over resolveComposed), the compose machinery
#       (composeManifest + mergeKeyed/mergeKeyedOptional/mergeStringsWithFloor/
#       mergeOptionalStrings/mergeMappingRules/canonicalKey, filterBorrowed,
#       resolveComposed, assertNoDanglingReferences) and the
#       BorrowedTypeNotFoundError/DanglingReferenceError classes. This code is
#       LIFTED VERBATIM from the proven full-file drop-in — only RELOCATED to a
#       pure end-of-file block. Semantics (child-wins over BOTH axes; precedence
#       leaf-own > explicit-borrow > extends-inherited; shared visiting-set
#       cycle guard + two budgets; standalone packs short-circuit BY REFERENCE
#       → byte-identical no-op) are unchanged from the proven version.
#
#   Because mergeExtendsChain returns the child BY REFERENCE for a standalone
#   pack (extends:null AND borrow_from empty), AND the inline `const merged`
#   guard only calls it when extends/borrow_from is present, a flat pack
#   (base/base-v2) takes the `: manifest` branch → `merged === manifest` →
#   buildAliasGraph(merged) === buildAliasGraph(manifest): byte-identical no-op
#   (base-v2 manifest_sha8 stays b9bebaa4).
#
# ANCHOR / GUARD STRATEGY  (replaces the old whole-file sha256 guard)
#   (a) ANCHOR-PRESENCE PREFLIGHT — exit 1 (build FAILS, old container keeps
#       serving) if the T20 comment OR any of the 3 target tokens is absent
#       (upstream moved the anchor / landed T20 → RE-POINT or RETIRE).
#   (b) MATCH-COUNT ASSERTION — each of the 3 substitutions MUST apply exactly
#       once (perl returns the count); 0 ⇒ exit 1. The splice can NEVER silently
#       no-op. (We do NOT pin a whole-file checksum: the splice is surgical and
#       self-verifying; a checksum gate would just churn on every unrelated
#       upstream edit to registry.ts.)
#   Idempotency: marker VF-FIX-SP-MERGE makes a re-run a no-op. Post-write:
#   marker re-grep + `gbrain --version` smoke + `tsc --noEmit` on registry.ts.
#
# gbrain CORE modification — applied at Docker BUILD after the gbrain install,
# baked in, re-applied on every GBRAIN_REF bump. RE-VALIDATE ON EVERY UPGRADE.
# Registry: hermes-workspace/MODIFICATIONS.md.
# ---------------------------------------------------------------------------
set -euo pipefail
GBRAIN_SRC=""
for d in \
  "${GBRAIN_SRC_OVERRIDE:-}" \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -n "$d" ] && [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then echo "[sp-merge] ERROR: gbrain src tree not found." >&2; exit 1; fi
echo "[sp-merge] target: $GBRAIN_SRC"
REG="$GBRAIN_SRC/core/schema-pack/registry.ts"
[ -f "$REG" ] || { echo "[sp-merge] ERROR: $REG not found — layout changed. RE-POINT." >&2; exit 1; }
MARKER='VF-FIX-SP-MERGE'
if grep -qF "$MARKER" "$REG"; then echo "[sp-merge] ✓ already applied; no-op."; exit 0; fi

# ---- (a) ANCHOR-PRESENCE PREFLIGHT --------------------------------------
# All anchors must be present in the PRISTINE shape before we splice. Any
# absence ⇒ upstream moved the anchor or landed the T20 follow-up ⇒ FAIL LOUD.
ANCHOR_T20='// Full extends-merging (child-wins) is the v0.41+ T20 follow-up.'
ANCHOR_AG='const alias_graph = buildAliasGraph(manifest);'
ANCHOR_CH='const alias_closure_hash = await computeAliasClosureHash(manifest);'
ANCHOR_LIT_RE='^    manifest,$'
miss=0
grep -qF "$ANCHOR_T20" "$REG" || { echo "[sp-merge] ANCHOR MISSING: T20 follow-up comment (upstream may have LANDED the merge → review/RETIRE this patch)." >&2; miss=1; }
grep -qF "$ANCHOR_AG"  "$REG" || { echo "[sp-merge] ANCHOR MISSING: 'const alias_graph = buildAliasGraph(manifest);' → RE-POINT." >&2; miss=1; }
grep -qF "$ANCHOR_CH"  "$REG" || { echo "[sp-merge] ANCHOR MISSING: 'const alias_closure_hash = await computeAliasClosureHash(manifest);' → RE-POINT." >&2; miss=1; }
grep -qE "$ANCHOR_LIT_RE" "$REG" || { echo "[sp-merge] ANCHOR MISSING: ResolvedPack literal field '    manifest,' → RE-POINT." >&2; miss=1; }
# import anchors (the two manifest-v1 import lines we widen)
ANCHOR_IMP_TYPE="import type { SchemaPackManifest } from './manifest-v1.ts';"
ANCHOR_IMP_VAL="import { computeManifestSha8, packIdentity } from './manifest-v1.ts';"
grep -qF "$ANCHOR_IMP_TYPE" "$REG" || { echo "[sp-merge] ANCHOR MISSING: manifest-v1 type-import line → RE-POINT." >&2; miss=1; }
grep -qF "$ANCHOR_IMP_VAL"  "$REG" || { echo "[sp-merge] ANCHOR MISSING: manifest-v1 value-import line → RE-POINT." >&2; miss=1; }
if [ "$miss" != "0" ]; then
  echo "[sp-merge] ERROR: one or more anchors absent — the splice would be unsafe. RE-POINT or RETIRE (UPGRADING_GBRAIN.md → 'Re-pointing the schema-pack merge anchor-splice')." >&2
  exit 1
fi
echo "[sp-merge] anchor preflight OK (all 6 anchors present)."

# ---- (b) THE SPLICE (perl, with match-count assertions) -----------------
# Each substitution returns the number of replacements; we assert == 1 so the
# splice can NEVER silently no-op (the green-but-broken hole under a splice).
perl -0777 -i -pe '
  our $imp_type = s/\Qimport type { SchemaPackManifest } from '"'"'.\/manifest-v1.ts'"'"';\E/import type {\n  SchemaPackManifest,\n  PackPageType,\n  PackLinkType,\n  PackMappingRule,\n} from '"'"'.\/manifest-v1.ts'"'"';/g;
  END { $main::imp_type = $imp_type }
' "$REG"
perl -0777 -i -pe '
  our $imp_val = s/\Qimport { computeManifestSha8, packIdentity } from '"'"'.\/manifest-v1.ts'"'"';\E/import {\n  computeManifestSha8,\n  packIdentity,\n  parseSchemaPackManifest,\n} from '"'"'.\/manifest-v1.ts'"'"';/g;
  END { $main::imp_val = $imp_val }
' "$REG"

# Insert `const merged = …` immediately before the alias_graph build, then swap
# the two alias consumers and the ResolvedPack literal field. We do these as
# separate perl invocations so each returns its own count.
INS='const merged = (manifest.extends || (manifest.borrow_from && manifest.borrow_from.length)) ? await mergeExtendsChain(manifest, loadByName, opts) : manifest;'
# 1: insert const merged before the alias_graph line (anchored on that line)
C1=$(perl -0777 -i -pe 'BEGIN{$c=0} $c += s/(\n)(  const alias_graph = buildAliasGraph\(manifest\);)/$1  '"$INS"'$1$2/g; END{print STDERR "C1=$c\n"}' "$REG" 2>&1 >/dev/null; true)
# 2: swap buildAliasGraph(manifest) -> (merged)
C2=$(perl -0777 -i -pe 'BEGIN{$c=0} $c += s/buildAliasGraph\(manifest\)/buildAliasGraph(merged)/g; END{print STDERR "C2=$c\n"}' "$REG" 2>&1 >/dev/null; true)
# 3: swap computeAliasClosureHash(manifest) -> (merged)
C3=$(perl -0777 -i -pe 'BEGIN{$c=0} $c += s/computeAliasClosureHash\(manifest\)/computeAliasClosureHash(merged)/g; END{print STDERR "C3=$c\n"}' "$REG" 2>&1 >/dev/null; true)
# 4: swap the ResolvedPack literal field `    manifest,` -> `    manifest: merged,`
C4=$(perl -0777 -i -pe 'BEGIN{$c=0} $c += s/^    manifest,$/    manifest: merged,/mg; END{print STDERR "C4=$c\n"}' "$REG" 2>&1 >/dev/null; true)

getc(){ echo "$1" | sed -n 's/^C[0-9]=//p'; }
n1=$(getc "$C1"); n2=$(getc "$C2"); n3=$(getc "$C3"); n4=$(getc "$C4")
echo "[sp-merge] splice match-counts: const-merged=$n1 buildAliasGraph=$n2 computeAliasClosureHash=$n3 literal=$n4"
fail=0
[ "$n1" = "1" ] || { echo "[sp-merge] MATCH-COUNT FAIL: const-merged insertion applied $n1 times (expected 1)." >&2; fail=1; }
[ "$n2" = "1" ] || { echo "[sp-merge] MATCH-COUNT FAIL: buildAliasGraph swap applied $n2 times (expected 1)." >&2; fail=1; }
[ "$n3" = "1" ] || { echo "[sp-merge] MATCH-COUNT FAIL: computeAliasClosureHash swap applied $n3 times (expected 1)." >&2; fail=1; }
[ "$n4" = "1" ] || { echo "[sp-merge] MATCH-COUNT FAIL: ResolvedPack literal swap applied $n4 times (expected 1)." >&2; fail=1; }
if [ "$fail" != "0" ]; then
  echo "[sp-merge] ERROR: splice did not apply cleanly — registry.ts shape drifted. RE-POINT." >&2
  exit 1
fi

# ---- (3) EOF APPEND — the merge machinery (LIFTED VERBATIM, relocated) ---
cat >> "$REG" <<'VF_PATCH_EOF'

// ───────────────────────────────────────────────────────────────────────
// VF-FIX-SP-MERGE (#1749 + #1838) — full schema composition (child-wins)
// over BOTH the extends chain AND borrow_from. APPENDED as a pure end-of-file
// block (anchor-splice form, C+B refactor). resolvePack above feeds the MERGED
// manifest into buildAliasGraph/computeAliasClosureHash/the ResolvedPack
// literal via `const merged = … mergeExtendsChain(…) : manifest`.
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

// VF-FIX-SP-MERGE (adversarial §5b): TWO independent budgets bound the
// combined extends+borrow graph. (1) EXTENDS_DEPTH_HARD_CAP is the per-path
// EXTENDS chain length (the existing public const) AND, applied separately, the
// per-path BORROW recursion depth (kills the #1838 borrow→borrow ladder).
// Borrow BREADTH is NOT extends depth — a pack borrowing many shallow siblings
// must not blow the extends cap. (2) MERGE_TOTAL_RESOLUTIONS_CAP bounds the
// TOTAL number of resolveComposed() frames for one top-level resolve, catching
// a wide-and-deep graph that no single per-path cap would. Both throw
// ExtendsChainTooDeepError (the wire-stable error class).
export const MERGE_TOTAL_RESOLUTIONS_CAP = 64 as const;

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
    (fl: { page_type: string; link_type: string }) => `${fl.page_type} ${fl.link_type}`,
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
 * VF-FIX-SP-MERGE entry point (anchor-splice form). Called from resolvePack
 * ONLY when the leaf declares `extends` OR a non-empty `borrow_from` (the
 * inline `const merged = … : manifest` guard). Threads a fresh shared
 * visiting-set + the two budgets into resolveComposed. For a leaf that somehow
 * reaches here with no real composition (defensive), resolveComposed →
 * composeManifest returns the child BY REFERENCE, preserving the no-op.
 *
 * `deps` would let the caller extend the cache `chain` to borrowed packs too;
 * the splice keeps the upstream cache-snapshot logic (extends chain) as-is and
 * relies on the stat-TTL gate for freshness, so we discard `deps` here. (The
 * full-file form recorded borrowed deps in the chain; under the splice we keep
 * the upstream chain semantics to minimize surface area — borrowed-pack edits
 * are still picked up within the stat-TTL window on the parent's own files.)
 */
export async function mergeExtendsChain(
  manifest: SchemaPackManifest,
  loadByName: (name: string) => Promise<SchemaPackManifest>,
  opts: { onDepthWarn?: (depth: number, chain: string[]) => void } = {},
): Promise<SchemaPackManifest> {
  return resolveComposed(manifest, loadByName, {
    visiting: new Set<string>(),
    borrowDepth: 0,
    budget: { left: MERGE_TOTAL_RESOLUTIONS_CAP },
    deps: new Set<string>(),
    onDepthWarn: opts.onDepthWarn,
  });
}
VF_PATCH_EOF

grep -qF 'VF-FIX-SP-MERGE' "$REG" || { echo "[sp-merge] ERROR: marker absent post-write." >&2; exit 1; }
echo "[sp-merge] ✓ patch applied (registry.ts extends-merge anchor-splice)."

# ---- post-write type check (project tsc --noEmit) -----------------------
# Run the project's own `tsc --noEmit` (honors the repo tsconfig — which
# enables allowImportingTsExtensions etc.) so registry.ts is type-checked in
# context. We invoke node on typescript's own tsc.js (the node_modules/.bin/tsc
# shim is sometimes a broken stub in a global-install layout). Non-fatal: if
# the toolchain is absent we skip with a WARN — the `gbrain --version` smoke
# gate in the Dockerfile RUN line is the load-bearing post-check (a real type
# error there aborts module load and fails the build).
PKG_ROOT="$(cd "$GBRAIN_SRC/.." && pwd)"
TSC_JS=""
for cand in \
  "$PKG_ROOT/node_modules/typescript/lib/tsc.js" \
  "$GBRAIN_SRC/../../typescript/lib/tsc.js"; do
  [ -f "$cand" ] && { TSC_JS="$cand"; break; }
done
if [ -n "$TSC_JS" ] && [ -f "$PKG_ROOT/tsconfig.json" ]; then
  echo "[sp-merge] tsc --noEmit (project) ..."
  if ( cd "$PKG_ROOT" && node "$TSC_JS" --noEmit >/tmp/sp-merge-tsc.log 2>&1 ); then
    echo "[sp-merge] ✓ tsc --noEmit clean (whole project, registry.ts included)."
  else
    REG_ERRS="$(grep -c 'core/schema-pack/registry.ts' /tmp/sp-merge-tsc.log || true)"
    if [ "${REG_ERRS:-0}" != "0" ]; then
      echo "[sp-merge] ERROR: tsc reported $REG_ERRS error(s) IN registry.ts (see /tmp/sp-merge-tsc.log)." >&2
      grep 'core/schema-pack/registry.ts' /tmp/sp-merge-tsc.log >&2 || true
      exit 1
    fi
    echo "[sp-merge] WARN: tsc reported pre-existing project errors OUTSIDE registry.ts (none in registry.ts). Proceeding — the gbrain --version smoke gate is authoritative."
  fi
else
  echo "[sp-merge] (tsc/tsconfig not available — relying on the gbrain --version smoke gate)."
fi
