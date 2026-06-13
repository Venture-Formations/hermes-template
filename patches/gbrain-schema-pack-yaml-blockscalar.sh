#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gbrain-schema-pack-yaml-blockscalar.sh   (VF-FIX-SP-YAML)
#
# WHY THIS EXISTS
#   Upstream #1750 (open, confirmed broken @ 4ee530f): loader.ts hand-rolled
#   parseYamlMini has NO block-scalar support — a `description: |` (literal)
#   parses the bare "|" then the indented body line trips parseMapping's
#   `if (indent > baseIndent) break`, SILENTLY dropping page_types: and every
#   later key. A custom pack authored with a multi-line description resolves
#   to 0 page_types.
#
# WHAT THIS PATCH DOES
#   FULL-FILE REPLACEMENT of src/core/schema-pack/loader.ts keyed to 4ee530f.
#   parseYamlMini now delegates to js-yaml safeLoad under JSON_SCHEMA (js-yaml
#   @3.14.2 is ALREADY a prod dep, imported by src/core/markdown.ts — zero new
#   deps; JSON_SCHEMA keeps `version:`/dates as strings, matching the old
#   parser's behavior) behind a fail-loud rejector for anchors (&) / aliases
#   (*) / merge-keys (<<) / tags (!) — js-yaml would silently RESOLVE those;
#   the pack contract is "ship JSON if you need them". The rejector blanks
#   quoted spans + comments first, so base-v2's quoted "*unknown*" /
#   "*original_type*" are NOT false positives. Signature + export of
#   parseYamlMini are preserved (mutate.ts writePackManifest round-trip + the
#   test suite import it). Byte-bounded (1 MiB) before the engine runs.
#
# ANCHOR / GUARD STRATEGY
#   PRE-CLOBBER sha256 guard: loader.ts must be pristine 4ee530f (57fd73ee…).
#   Mismatch ⇒ exit 1 ⇒ build fails. Idempotency: marker VF-FIX-SP-YAML.
#   Post-write audit re-greps the marker + the parseYamlMini export + the
#   js-yaml import.
#
# gbrain CORE modification — Docker BUILD, baked in, re-applied per GBRAIN_REF
# bump. RE-VALIDATE ON EVERY UPGRADE. Registry: hermes-workspace/MODIFICATIONS.md.
# ---------------------------------------------------------------------------
set -euo pipefail
GBRAIN_SRC=""
for d in \
  "${BUN_INSTALL:-/usr/local/bun}/install/global/node_modules/gbrain/src" \
  "/usr/local/bun/install/global/node_modules/gbrain/src" \
  "${HOME:-/root}/.bun/install/global/node_modules/gbrain/src"; do
  if [ -d "$d" ]; then GBRAIN_SRC="$d"; break; fi
done
if [ -z "$GBRAIN_SRC" ]; then echo "[sp-yaml] ERROR: gbrain src tree not found." >&2; exit 1; fi
echo "[sp-yaml] target: $GBRAIN_SRC"
LOA="$GBRAIN_SRC/core/schema-pack/loader.ts"
[ -f "$LOA" ] || { echo "[sp-yaml] ERROR: $LOA not found — layout changed. RE-POINT." >&2; exit 1; }
MARKER='VF-FIX-SP-YAML'
if grep -qF "$MARKER" "$LOA"; then echo "[sp-yaml] ✓ already applied; no-op."; exit 0; fi
sha_of(){ sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }
LOA_VANILLA_SHA="57fd73eef9894d699227d63eff628f44f722ee52583898c3532d5ea2aecd55ba"
GOT="$(sha_of "$LOA")"
if [ "$GOT" != "$LOA_VANILLA_SHA" ]; then
  echo "[sp-yaml] ERROR: loader.ts drift — NOT the 4ee530f version." >&2
  echo "[sp-yaml]   expected $LOA_VANILLA_SHA" >&2
  echo "[sp-yaml]   got      $GOT" >&2
  echo "[sp-yaml]   RE-KEY THIS DROP-IN (UPGRADING_GBRAIN.md → 'Re-keying a full-file-replacement patch')." >&2
  exit 1
fi
echo "[sp-yaml] pre-clobber guard OK (loader.ts is pristine 4ee530f)."
# ---- loader.ts (corrected drop-in, carries marker VF-FIX-SP-YAML) ----
cat > "$LOA" <<'VF_PATCH_EOF'
// v0.38 Schema Pack loader — YAML/JSON sniffing + normalization.
//
// Pack authors choose YAML or JSON. The loader sniffs by file extension
// (`.yaml` / `.yml` / `.json`), parses through the appropriate path, and
// normalizes to a single `SchemaPackManifest` shape before validation
// (manifest-v1.ts handles the validation half).
//
// YAML parsing: hand-rolled following the `storage-config.ts` pattern.
// Avoids js-yaml dependency add (gbrain already ships ~70% of its YAML
// touchpoints hand-parsed). For pack manifests, the YAML subset we accept
// is intentionally narrow: scalars, lists, nested objects up to 4 levels
// deep, no anchors, no aliases, no tags. If users want broader YAML,
// they ship JSON.
//
// Fail-loud: malformed YAML throws SchemaPackLoaderError with line/col
// when available. Empty file → INVALID_SHAPE. Unknown extension → falls
// through to JSON.parse attempt.

import { readFileSync } from 'node:fs';
import { extname } from 'node:path';
import { parseSchemaPackManifest, type SchemaPackManifest } from './manifest-v1.ts';
import { safeLoad as yamlSafeLoad, JSON_SCHEMA } from 'js-yaml'; // VF-FIX-SP-YAML

export class SchemaPackLoaderError extends Error {
  readonly code: 'PARSE_ERROR' | 'FILE_NOT_FOUND' | 'UNSUPPORTED_EXTENSION';
  readonly path: string;

  constructor(code: 'PARSE_ERROR' | 'FILE_NOT_FOUND' | 'UNSUPPORTED_EXTENSION', message: string, path: string) {
    super(message);
    this.name = 'SchemaPackLoaderError';
    this.code = code;
    this.path = path;
  }
}

/**
 * Load + parse + validate a pack from disk. Returns the validated manifest.
 * Throws SchemaPackLoaderError (file/parse errors) or
 * SchemaPackManifestError (shape/version errors).
 */
export function loadPackFromFile(path: string): SchemaPackManifest {
  let content: string;
  try {
    content = readFileSync(path, 'utf-8');
  } catch (e) {
    throw new SchemaPackLoaderError('FILE_NOT_FOUND', `cannot read pack file: ${(e as Error).message}`, path);
  }
  return loadPackFromString(content, path);
}

/**
 * Parse a manifest from a raw string. Extension-driven; `.json` uses
 * JSON.parse, anything else uses the YAML mini-parser. Test seam.
 */
export function loadPackFromString(content: string, hint: string): SchemaPackManifest {
  const ext = extname(hint).toLowerCase();
  let raw: unknown;
  if (ext === '.json') {
    try {
      raw = JSON.parse(content);
    } catch (e) {
      throw new SchemaPackLoaderError('PARSE_ERROR', `JSON parse error: ${(e as Error).message}`, hint);
    }
  } else {
    // Default to YAML for .yaml, .yml, and unknown extensions.
    try {
      raw = parseYamlMini(content);
    } catch (e) {
      throw new SchemaPackLoaderError('PARSE_ERROR', `YAML parse error: ${(e as Error).message}`, hint);
    }
  }
  return parseSchemaPackManifest(raw, { path: hint });
}

/**
 * Mini YAML parser for the schema-pack manifest subset.
 *
 * Accepted syntax:
 *   - Top-level mapping (key: value pairs)
 *   - Nested mappings via indentation (2-space convention)
 *   - Sequences via "- item" lines (lists of scalars or maps)
 *   - Scalar values: strings (quoted or bare), integers, booleans, null
 *   - `#` comments to end-of-line (outside string values)
 *   - Block strings via `|` (literal) or `>` (folded) NOT supported in v1
 *
 * Rejected by design: anchors (&), aliases (*), tags (!), flow style
 * ({...}, [...] except as JSON), block scalars (|, >), multi-document (---).
 * Pack authors who need these features should ship JSON.
 *
 * This is intentionally narrow. The skill-pack and storage-config parsers
 * use similar hand-rolled patterns; this one is shape-customized for pack
 * manifests (4-level nest, sequences-of-maps for page_types/link_types).
 */
export function parseYamlMini(content: string): unknown {
  // VF-FIX-SP-YAML (#1750) — upstream's hand-rolled parser silently DROPS
  // every key after a block scalar (`description: |`), yielding 0 page_types.
  // Delegate to js-yaml safeLoad (already a prod dep, used by markdown.ts)
  // under JSON_SCHEMA so `version: 1.x` / dates stay strings (matching the
  // hand-rolled parser's behavior, NOT auto-typed to Date). Fail-loud reject
  // of anchors/aliases/merge-keys/tags preserves the pack contract ("ship
  // JSON if you need those"). Signature + export unchanged (mutate.ts +
  // tests import parseYamlMini). Byte-bounded before the engine runs.
  const MAX_PACK_YAML_BYTES = 1 << 20; // 1 MiB
  if (content.length > MAX_PACK_YAML_BYTES) {
    throw new Error(`pack YAML exceeds ${MAX_PACK_YAML_BYTES} bytes`);
  }
  rejectUnsupportedYaml(content);
  let raw: unknown;
  try {
    raw = yamlSafeLoad(content, { schema: JSON_SCHEMA });
  } catch (e) {
    throw new Error((e as Error).message);
  }
  return raw === undefined ? null : raw;
}

/**
 * VF-FIX-SP-YAML — reject the YAML features the pack contract forbids
 * (anchors &, aliases *, merge-keys <<, tags !). js-yaml would silently
 * RESOLVE anchors/merge-keys; we want fail-loud. Scan line-oriented AFTER
 * blanking quoted strings + comments, so base-v2's quoted `"*unknown*"` /
 * `"*original_type*"` are NOT false positives.
 */
function rejectUnsupportedYaml(content: string): void {
  for (const rawLine of content.split(/\r?\n/)) {
    // blank quoted spans + trailing comment, char by char
    let s = '';
    let inS = false, inD = false;
    for (let j = 0; j < rawLine.length; j++) {
      const c = rawLine[j];
      if (c === "'" && !inD) { inS = !inS; s += ' '; continue; }
      if (c === '"' && !inS) { inD = !inD; s += ' '; continue; }
      if (c === '#' && !inS && !inD) break;
      s += (inS || inD) ? ' ' : c;
    }
    if (/(^|[\s:[,{])&[A-Za-z0-9_-]/.test(s)) throw new Error(`YAML anchor (&) is not supported in schema packs — ship JSON instead`);
    if (/(^|[\s:[,{])\*[A-Za-z0-9_-]/.test(s)) throw new Error(`YAML alias (*) is not supported in schema packs — ship JSON instead`);
    if (/(^|\s)<<\s*:/.test(s)) throw new Error(`YAML merge key (<<) is not supported in schema packs — ship JSON instead`);
    if (/(^|[\s:[,{])!![A-Za-z]/.test(s) || /(^|[\s:[,{])!<?[A-Za-z]/.test(s)) throw new Error(`YAML tag (!) is not supported in schema packs — ship JSON instead`);
  }
}
VF_PATCH_EOF
fail=0
grep -qF 'VF-FIX-SP-YAML' "$LOA" || { echo "[sp-yaml] ERROR: marker absent post-write." >&2; fail=1; }
grep -qF 'export function parseYamlMini' "$LOA" || { echo "[sp-yaml] ERROR: parseYamlMini export lost." >&2; fail=1; }
grep -qF "from 'js-yaml'" "$LOA" || { echo "[sp-yaml] ERROR: js-yaml import absent." >&2; fail=1; }
[ "$fail" -eq 0 ] || exit 1
echo "[sp-yaml] ✓ patch applied (loader.ts js-yaml block-scalar fix)."
