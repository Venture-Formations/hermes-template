# WS4 — rewire the "gbrain daily update watcher" through the dry-run gate

**Status:** DRAFT for the operator to apply via `/schedule`. This documents the
change to a REMOTE routine; nothing here is auto-applied by a build.

## What changes, in one sentence

Today the "gbrain daily update watcher" routine finds the newest
`garrytan/gbrain` master commit and bumps `ARG GBRAIN_REF` in the Dockerfile
straight to it (Railway then rebuilds prod). **Rewire it so it first runs the
new pre-prod gate `.github/workflows/gbrain-bump-dryrun.yml` against the
candidate ref, and only bumps `ARG GBRAIN_REF` + merges when that run is GREEN;
on RED it opens a tracking issue and bumps nothing.**

This makes a moved-anchor patch, a failed `anthropic-scan`, a candidate that
won't load, or a probe that can't answer (UNKNOWN) a *caught-before-prod* event
instead of a green-`doctor`/silent-zero surprise after Railway has already
swapped containers.

## Why the gate is the right cut point

- The dry-run installs the candidate ref into a **vanilla** tree exactly as the
  Dockerfile does (`bun install -g github:garrytan/gbrain#<ref>` with
  `BUN_INSTALL=/usr/local/bun`), then applies **all** `patches/gbrain-*.sh`,
  runs `anthropic-scan.sh`, and re-checks `gbrain --version`. That is the same
  sequence the prod Docker build runs — so **GREEN here predicts a green prod
  build**, and RED here is a prod build that *would have* failed (best case) or
  silently degraded (worst case) caught one step earlier.
- It also runs the **per-patch probe matrix** (`patches/*.probe.sh`) against the
  candidate, classifying each patch STILL-NEEDED / OBSOLETE / UNKNOWN. OBSOLETE
  is recommend-only (a patch gbrain may have fixed upstream — surfaced for
  retirement, never blocks the bump). UNKNOWN is treated as RED.
- The watcher must NOT replicate this logic itself — it just dispatches the
  workflow and reads the conclusion. The gate is the single source of "is this
  ref safe?", which keeps the watcher thin and the gate authoritative.

## Preconditions (one-time, operator)

1. The workflow file `.github/workflows/gbrain-bump-dryrun.yml` is on the branch
   GitHub Actions runs workflows from for this repo. Workflows are picked up from
   the **default branch** for `schedule`/`workflow_dispatch`; if prod lives only
   on `deploy/venture-formations-fork`, either land this workflow on the default
   branch too, or dispatch with `--ref deploy/venture-formations-fork`.
2. The routine's runner has a `gh` CLI authenticated against
   `Venture-Formations/hermes-template` with `actions:write` (dispatch + read
   runs) and `issues:write` (open the RED issue). The existing watcher already
   edits the Dockerfile/pushes, so it has repo write; confirm `actions` +
   `issues` scopes are present.
3. (Optional) Set a `SLACK_WEBHOOK_URL` **repo secret** to also fan the
   GREEN/RED verdict into Slack from the workflow itself. Absent = the workflow
   simply skips the Slack step (non-fatal); the watcher's own notification path
   is unaffected.

## The rewired routine (drop-in for the `/schedule` prompt body)

> Replace the watcher's "bump `ARG GBRAIN_REF` to the newest master commit"
> action with the gated flow below. Everything else (how it discovers the
> candidate commit) stays as-is.

```bash
set -euo pipefail
REPO="Venture-Formations/hermes-template"
WORKFLOW="gbrain-bump-dryrun.yml"
# The branch the workflow file + Dockerfile live on for prod:
PROD_BRANCH="deploy/venture-formations-fork"

# 1. CANDIDATE: newest garrytan/gbrain master commit (the watcher already
#    computes this — reuse its value).
CANDIDATE="$(gh api repos/garrytan/gbrain/commits/master --jq .sha)"

# 2. CURRENT pinned ref in the Dockerfile (skip if unchanged).
CURRENT="$(gh api "repos/${REPO}/contents/Dockerfile?ref=${PROD_BRANCH}" \
  --jq '.content' | base64 -d \
  | sed -n 's/^ARG GBRAIN_REF=\(.*\)$/\1/p' | head -1)"
if [ "${CANDIDATE}" = "${CURRENT}" ]; then
  echo "No new gbrain commit (still ${CURRENT}); nothing to do."
  exit 0
fi

# 3. GATE: run the dry-run workflow against the candidate and WAIT for it.
gh workflow run "${WORKFLOW}" \
  --repo "${REPO}" \
  --ref "${PROD_BRANCH}" \
  -f gbrain_ref="${CANDIDATE}"

# Resolve the run id we just created (newest run of this workflow on this ref),
# then block on it.
sleep 8
RUN_ID="$(gh run list --repo "${REPO}" --workflow "${WORKFLOW}" \
  --branch "${PROD_BRANCH}" --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "${RUN_ID}" --repo "${REPO}" --exit-status && GATE=GREEN || GATE=RED
RUN_URL="$(gh run view "${RUN_ID}" --repo "${REPO}" --json url --jq .url)"

# 4a. GREEN => bump ARG GBRAIN_REF + merge (this is the ONLY path that touches prod).
if [ "${GATE}" = "GREEN" ]; then
  echo "GATE GREEN for ${CANDIDATE} — bumping ARG GBRAIN_REF (${CURRENT} -> ${CANDIDATE})."
  # Use the watcher's existing edit-Dockerfile-and-push mechanism, e.g.:
  #   - check out PROD_BRANCH
  #   - sed -i "s|^ARG GBRAIN_REF=.*|ARG GBRAIN_REF=${CANDIDATE}|" Dockerfile
  #     (also refresh the "Current: vX — master @ <date>, commit <short>" comment)
  #   - commit "Dockerfile: bump GBRAIN_REF ${CURRENT:0:7} -> ${CANDIDATE:0:7} (dry-run GREEN ${RUN_URL})"
  #   - push to PROD_BRANCH  (Railway rebuilds onto the new, gate-proven ref)
  # NOTE: the prod Docker build re-runs every patch + anthropic-scan again, so a
  # GREEN gate + a successful Railway build are belt-and-suspenders.
  echo "Pushed bump; Railway will rebuild ${PROD_BRANCH}."

# 4b. RED => bump NOTHING; open a tracking issue with the failing detail.
else
  echo "GATE RED for ${CANDIDATE} — NOT bumping. Opening issue."
  gh issue create --repo "${REPO}" \
    --title "gbrain bump BLOCKED: candidate ${CANDIDATE:0:7} failed the dry-run gate" \
    --label "gbrain-upgrade,blocked" \
    --body "$(printf '%s\n' \
      "The daily watcher found a new garrytan/gbrain master commit but the pre-prod" \
      "dry-run gate came back **RED**, so \`ARG GBRAIN_REF\` was **NOT** bumped." \
      "" \
      "- **Candidate ref:** \`${CANDIDATE}\`" \
      "- **Current (still deployed) ref:** \`${CURRENT}\`" \
      "- **Dry-run run:** ${RUN_URL}" \
      "" \
      "**Open the run summary** for the blocking reason — it names the failing" \
      "patch (anchor moved → re-point per its \`.meta.yml\` anchor), an \`anthropic-scan\`" \
      "failure (no-native-Anthropic guarantee broke), a candidate that won't load," \
      "or a probe that returned UNKNOWN. Fix or re-point the patch on a branch, re-run" \
      "the gate (\`gh workflow run ${WORKFLOW} -f gbrain_ref=${CANDIDATE}\`), and only" \
      "merge once it is GREEN. See UPGRADING_GBRAIN.md.")"
  echo "Issue opened; prod stays on ${CURRENT}."
fi

echo "Watcher done: candidate=${CANDIDATE} gate=${GATE} ${RUN_URL}"
```

## Decision table

| Gate verdict | `ARG GBRAIN_REF` | Action |
|---|---|---|
| GREEN (all patches apply, scan OK, version OK, no UNKNOWN probe) | **bump → candidate** | commit + push `PROD_BRANCH`; Railway rebuilds |
| RED (a patch failed to apply / scan failed / version broke / a probe UNKNOWN) | **unchanged** | open a `gbrain-upgrade,blocked` issue with the run URL; prod stays put |
| GREEN **with OBSOLETE patches listed** | **bump → candidate** (still safe) | bump proceeds; the OBSOLETE list in the summary is a recommend-only nudge to retire those patches per each `deprecate_when` — handle separately, do not block the bump |

## Invariants this rewire must preserve

- **Only GREEN touches prod.** The bump+push is reachable solely on the GREEN
  branch. No "bump anyway / override" path in the routine.
- **The watcher never re-implements the checks.** It dispatches the workflow and
  reads the conclusion; the gate (`gbrain-bump-dryrun.yml`) is the single source
  of truth for "is this ref safe?". If a check needs to change, change the
  workflow, not the watcher.
- **RED is observable, not silent.** Every RED opens an issue with the run URL so
  a blocked upgrade is visible, not a no-op that looks like "no new commit".
- **Idempotent on no-change.** If the newest commit already equals the deployed
  `GBRAIN_REF`, the routine exits early and dispatches nothing.

## Manual operator use (outside the routine)

```bash
# Dry-run any candidate ref by hand before merging a Dockerfile bump:
gh workflow run gbrain-bump-dryrun.yml \
  --repo Venture-Formations/hermes-template \
  --ref deploy/venture-formations-fork \
  -f gbrain_ref=<candidate-sha>
gh run watch "$(gh run list --workflow gbrain-bump-dryrun.yml --limit 1 \
  --json databaseId --jq '.[0].databaseId')" --exit-status
# Read the run's job summary for the per-patch probe matrix + GREEN/RED verdict.
```

Related: `UPGRADING_GBRAIN.md` (the manual upgrade procedure this gate
front-runs), `CLAUDE.md` → "gbrain core patches" (why each patch is fail-closed
and carries a `.probe.sh`), and the generated `hermes-workspace/MODIFICATIONS.md`
(the authoritative patch registry).
