# WS4 — gate the gbrain daily update watcher on a pre-bump dry-run

## How gbrain is updated TODAY (the real mechanism)

gbrain ships via `garrytan/gbrain` `master` with no release tags. The image
bakes a specific commit via `ARG GBRAIN_REF=<sha>` in the Dockerfile. The
**"gbrain daily update watcher"** — a *remote `/schedule` routine* (daily 08:00
UTC, routine id `trig_014tp3y13cfjk7xTRBa8ozjW`) — compares `master`'s version to
the pinned ref and, if strictly newer, **edits `ARG GBRAIN_REF`, commits, and
pushes DIRECTLY to `deploy/venture-formations-fork`** (no PR), which Railway
rebuilds. The only safety today is the **fail-closed Docker build** (a patch that
won't apply fails the build; the old container keeps serving).

There is no PR and no default-branch CI involved — so a GitHub Actions
`workflow_dispatch`/PR gate is the WRONG vehicle (it was removed). The correct
gate runs **inside the routine, before it pushes the bump.**

## The gate: `tools/gbrain-bump-dryrun.sh`

A repo-versioned, Docker-free dry-run. Given a candidate gbrain sha it installs
that gbrain to a throwaway bun prefix, runs every `patches/*.probe.sh` (per-patch
obsolescence matrix), then applies every patch + `anthropic-scan.sh` +
`gbrain --version`. **Exit 0 = GREEN (safe to bump); non-zero = RED (names the
patch that needs re-pointing for the new ref).**

```
bash tools/gbrain-bump-dryrun.sh <candidate-sha>
```

## The routine change (applied via `/schedule`)

Insert the gate between "detect strictly-newer master" (step 5) and "bump +
push" (steps 6–7) of the watcher routine prompt:

> **5b. PRE-BUMP GATE (required).** Before changing anything, run
> `bash tools/gbrain-bump-dryrun.sh $MASTER_SHA` from the hermes-template
> checkout. Read its final `[bump-dryrun] RESULT:` line.
> - **GREEN** → proceed to bump + push (steps 6–7 unchanged). Include any
>   `OBSOLETE` patch names from the dry-run in the Slack message as
>   recommend-only retirement candidates.
> - **RED** → make NO changes, do NOT bump. Slack Jake: "gbrain bump to
>   `<MASTER_VERSION>` (`<short_sha>`) BLOCKED by the pre-bump dry-run — a
>   gbrain-core patch needs re-pointing for the new ref," plus the failing
>   `✗` line(s) from the dry-run output. Stop.

This is strictly safer than today: the worst case is *skipping* a bump (and
alerting), never pushing a bump that a patch can't survive.

## Why not just rely on the fail-closed build?
The fail-closed build already prevents a bad bump from reaching prod. The
dry-run adds: (a) the bad bump is never even committed (no wasted prod build, no
red `deploy` history), and (b) the per-patch obsolescence report surfaces
patches to retire — neither of which the build gives you.
