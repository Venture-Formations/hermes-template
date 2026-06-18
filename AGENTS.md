# AGENTS.md — hermes-template (fork)

You're working on the **Venture-Formations fork of praveen-ks-2001/hermes-agent-template**.
This is the Docker wrapper that Railway deploys.

## What this repo is

A fork of [`praveen-ks-2001/hermes-agent-template`](https://github.com/praveen-ks-2001/hermes-agent-template) — a
Railway-friendly Docker template that clones Hermes Agent, installs
dependencies, builds the React dashboard, and runs the gateway.

Lives at `Venture-Formations/hermes-template` on GitHub.
Railway's deployed service watches the
`deploy/venture-formations-fork` branch on this fork.

## Why we forked

Two reasons:

1. We pin a forked Hermes Agent (`Venture-Formations/hermes-agent`)
   instead of upstream. That requires the Dockerfile to point at our
   repo URL.
2. Generalising the `git clone` URL via an `ARG` makes future fork
   switches a one-line Dockerfile change instead of a search-and-
   replace.

## Our changes — Dockerfile parameterisation

We parameterised the `git clone` line in `Dockerfile`:

```dockerfile
# Before (upstream):
ARG HERMES_REF=v2026.5.16
RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
    ...

# After (us):
ARG HERMES_REPO=Venture-Formations/hermes-agent
ARG HERMES_REF=fix/parallel-tool-calls-v2026.5.29.2
RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/${HERMES_REPO}.git /opt/hermes-agent && \
    ...
```

To revert to vanilla upstream: set `HERMES_REPO=NousResearch/hermes-agent`
and `HERMES_REF=<latest upstream tag>`.

The clone-line parameterisation was our **first** change, but it is no
longer the only one. The deploy branch has since grown additional VF
customizations (detailed in the sections below):

- **`Dockerfile`** — the `HERMES_REPO`/`HERMES_REF` params above, plus the
  **gbrain binary bake** (`bun install -g github:garrytan/gbrain#${GBRAIN_REF}`
  → `/usr/local/bun`, **PINNED** to a specific commit via `ARG GBRAIN_REF` —
  bumped to a newer master commit by the "gbrain daily update watcher" routine;
  `unzip` added to apt) and the **youtube-collector deps** (`yt-dlp` + `ffmpeg`,
  baked for the `youtube-playlist-sync` cron), plus the **gbrain core patches**
  (`COPY patches/` + a `RUN bash patches/<patch>.sh` per patch right after the
  bake — see "gbrain core patches" below).
- **`patches/` — gbrain CORE patches** (the authoritative list is the generated
  `hermes-workspace/MODIFICATIONS.md`). The load-bearing one is
  **`gbrain-no-anthropic-reroute.sh` (FIX-NA-1)** + its fail-closed
  **`anthropic-scan.sh`**: a single guard at gbrain's `resolveRecipe()` chokepoint
  re-routes native `anthropic:` ids → the live default (FIX-NA-1 emits
  `openrouter:auto`, which the FIX-GROK-1 patch repoints to `grok:grok-4.3` via the
  keyless Hermes xAI-OAuth proxy recipe) so the brain runs on the operator's grok /
  SuperGrok subscription (we have no `ANTHROPIC_API_KEY`, and `OPENROUTER_API_KEY`
  was removed from Railway 2026-06-14). Replaces the retired
  literal-rewrite `gbrain-openrouter-model-defaults.sh`. Each patch is applied at
  build time, re-applied on every `GBRAIN_REF` bump, self-audits (fails the build
  on anchor drift), and carries a `<id>.probe.sh` obsolescence check. **⚠️ must be
  re-validated on every gbrain upgrade** — see the dedicated section below and
  `UPGRADING_GBRAIN.md`.
- **`start.sh`** — the **gbrain autopilot bootstrap** block (runs
  `gbrain autopilot --install --no-inject` + launches the daemon before
  `exec python /app/server.py`), plus the **gbrain HTTP MCP server** block.

Files VF has **not** modified — `server.py`, `requirements.txt`,
`railway.toml`, `templates/` — remain upstream. (They can still show a diff
against the latest `praveen-ks-2001/main` simply because this branch hasn't
rebased onto upstream's newer commits, not because VF edited them.)

## Branch topology

```
main                              ← tracks upstream praveen-ks-2001
                                    (clean mirror; NO VF customizations)
deploy/venture-formations-fork   ← the deployed branch (MULTI-commit, not
                                    a single commit): HERMES_REPO/REF params
                                    + version bumps, gbrain bake + youtube
                                    deps in Dockerfile, gbrain autopilot in
                                    start.sh. RAILWAY WATCHES THIS BRANCH.
```

## Upgrade procedure

When **upstream Hermes Agent** ships a new tag and we've updated
`Venture-Formations/hermes-agent` with a `fix/parallel-tool-calls-v<NEW>`
branch:

```bash
git checkout deploy/venture-formations-fork
# edit Dockerfile: change HERMES_REF to fix/parallel-tool-calls-v<NEW>
git add Dockerfile && git commit -m "Dockerfile: bump HERMES_REF to v<NEW>"
git push
```

Railway auto-detects the push and rebuilds. ~5 min build time, then
healthcheck + swap.

When **upstream template** ships improvements:

```bash
git fetch upstream
git checkout deploy/venture-formations-fork
git rebase upstream/main
# resolve Dockerfile conflicts (our parameterisation vs their changes)
git push --force-with-lease
```

Or, if the rebase looks messy, cherry-pick our Dockerfile change onto
a fresh branch from `upstream/main` and re-deploy from that.

## What's safe vs unsafe to modify

✅ **Modify freely:**
- `Dockerfile` `HERMES_REF` — bump when upgrading Hermes Agent.
- `Dockerfile` `HERMES_REPO` — flip if we ever want to point at a
  different fork (e.g. revert to upstream).
- Our deploy branch metadata.

⚠️ **Caution:**
- Upstream-template parts of `Dockerfile` (base image, hermes-agent
  clone/build, TUI prebuild) — upstream-managed; rebases will conflict.
- The `Dockerfile` **gbrain-bake** and **youtube-deps** blocks, and the
  `start.sh` **gbrain autopilot bootstrap** block — VF additions. Preserve
  them across rebases (they live alongside upstream content in those files).
- `server.py`, `requirements.txt`, `railway.toml`, `templates/` —
  upstream-managed; VF has not modified these.

❌ **Never:**
- Modify `main` directly. `main` should always be a clean mirror of
  `praveen-ks-2001/hermes-agent-template:main`.

## How Railway picks up changes

- Railway service: `Hermes Agent` in project `talented-education`.
- Source: `Venture-Formations/hermes-template`, branch
  `deploy/venture-formations-fork`.
- Trigger: every push to the watched branch fires a new deployment.
- Build: Docker, ~5 min on the SFO Metal builder.
- Healthcheck: `/health` endpoint, 5 min retry window.
- Swap: old container stays serving until new one passes healthcheck.

## How to verify the right thing is deployed

```bash
# 1. Confirm the deployed branch
railway service info --json | jq '.source'
# expect: {"repo": "Venture-Formations/hermes-template"}

# 2. Confirm the deployed Hermes version
railway service files download \
  /opt/hermes-agent/pyproject.toml /tmp/pyproject.toml
grep -E '^version|^name' /tmp/pyproject.toml
# expect:
#   name = "hermes-agent"
#   version = "0.15.2"   ← matches whichever HERMES_REF is set
```

## Upstream notes

- Upstream repo: `praveen-ks-2001/hermes-agent-template`
- This template is a Railway deployment helper around vanilla
  NousResearch/hermes-agent. Not officially maintained by Nous.
- We could in theory upstream the `HERMES_REPO` parameterisation as
  a PR. The user decided to hold it pending other priorities — see
  workspace `CHANGELOG.md`.

## gbrain topology (binary durability)

gbrain is now **baked into the Docker image**, not installed at runtime.

- **Binary path:** `/usr/local/bun/bin/gbrain`. The Dockerfile installs Bun
  with `BUN_INSTALL=/usr/local/bun` and runs `bun install -g
  github:garrytan/gbrain#${GBRAIN_REF}` — **pinned** to a specific commit via
  `ARG GBRAIN_REF` (the canonical install — see gbrain `INSTALL_FOR_AGENTS.md`
  Step 1 and `docs/operations/headless-install.md` Pattern 1 — with a
  reproducible pin so rebuilds are deterministic). `/usr/local/bun/bin` is on
  `PATH`, and a `gbrain --version` smoke check fails the build if the ref is
  unresolvable.
  - **Upgrades** bump `ARG GBRAIN_REF` to a newer `garrytan/gbrain` master
    commit — done autonomously by the "gbrain daily update watcher" remote
    routine (daily), or manually — and Railway rebuilds onto the new version.
    The on-container `gbrain-update-check` cron (in hermes-workspace) only
    *surfaces* available bumps notify-only; it never installs.
  - This **replaces the old ephemeral `/opt/bun/bin` assumption**, where
    gbrain lived on a path that vanished on every Railway rebuild.
- **Autopilot daemon at boot:** `start.sh` runs gbrain's canonical
  ephemeral-container launch before `exec python /app/server.py`:
  `gbrain autopilot --install --no-inject` writes
  `~/.gbrain/start-autopilot.sh` (Railway is detected as an
  ephemeral container via `RAILWAY_ENVIRONMENT`; see gbrain
  `skills/setup/SKILL.md` Phase C.5 and
  `src/commands/autopilot.ts` `installEphemeralContainer`), then
  `bash "$HOME/.gbrain/start-autopilot.sh"` nohup-launches the autopilot
  supervisor. We pass `--no-inject` because we are **not** OpenClaw — we
  launch the daemon explicitly rather than letting gbrain edit a bootstrap
  hook. The block is idempotent and strictly non-fatal: a gbrain failure is
  logged and never blocks the gateway.
- Autopilot self-supervises only its **Minions worker** (forks/restarts the
  worker on crash) — NOT its own tick-loop PROCESS. The ephemeral-container target
  ships no process supervisor (macos/systemd carry `Restart=always`), so a
  wedged/exited daemon strands (the 2026-06-18 ~25h `cycle_freshness` stall);
  `start.sh` now carries an autopilot liveness supervisor that relaunches it on a
  >=600s-stale `autopilot.lock` heartbeat. (Mirrors CLAUDE.md.)

## gbrain core patches (`patches/`)

These are gbrain CORE patches. The authoritative, GENERATED registry of every
core patch (and why each exists / when to retire it) is
`hermes-workspace/MODIFICATIONS.md` (🔴 gbrain core) — **do not hand-maintain a
count or list of core patches in prose here**; that is the drift the registry
exists to kill. Each patch has a `.meta.yml` sidecar, and the pre-commit registry
gate blocks any commit that adds/changes a patch without updating it. All core
patches are applied at Docker BUILD time (after the gbrain bake), baked into the
image, re-applied on every `GBRAIN_REF` bump, idempotent, and each is followed by
a `gbrain --version` smoke gate that fails the build if the patched tree won't
load.

> 🔁 **EVERY core patch MUST be re-validated on every gbrain release/`GBRAIN_REF`
> bump.** gbrain rewrites/moves the strings + lines they anchor on. Each patch
> self-audits and **fails the build** (old container keeps serving — no outage)
> if its anchor is gone, forcing a re-point — never a silent no-op. Each patch
> also carries a `<id>.probe.sh` (`still_needed_probe`) so the upgrade pipeline
> can answer, per patch, "did gbrain fix this upstream, so retire it?" This is a
> required step in `UPGRADING_GBRAIN.md`. The full set is in `MODIFICATIONS.md`;
> the two below are the load-bearing ones to understand.

### 1. `gbrain-no-anthropic-reroute.sh` (FIX-NA-1) — single-chokepoint no-Anthropic guard

**Why.** A gbrain model string's provider prefix selects the API key:
`anthropic:claude-sonnet-4-6` → Anthropic API (`ANTHROPIC_API_KEY`);
`openrouter:auto` → OpenRouter (`OPENROUTER_API_KEY`, may still route to Claude).
This deployment routes gbrain chat through the operator's grok / SuperGrok
subscription (keyless, via the Hermes xAI-OAuth proxy); the only provisioned LLM
key is `OPENAI_API_KEY` (utility paths). `OPENROUTER_API_KEY` was removed from
Railway 2026-06-14 — do NOT re-introduce an `openrouter:auto` route, it is unfunded.
(**never** a native Anthropic key — operator decision). gbrain hardcodes native
`anthropic:` defaults at dozens of touchpoints with no global config knob; any
that reach a native `anthropic:` recipe throw inside `chat()` and are swallowed
silently → the brain produces 0 facts with `doctor` green.

**What it does (replaces the retired `gbrain-openrouter-model-defaults.sh`).** The
old patch chased ~20 literals across a dozen files and audited "0 anthropic
literals remain" — a coverage boundary that lost to a release-less master (a new
touchpoint in an unmatched shape = a fresh silent zero). gbrain resolves EVERY
model string through one chokepoint — `resolveRecipe()` / `parseModelId()` in
`src/core/ai/model-resolver.ts` — so this patch injects a single guard there: a
native `anthropic:` id with no `ANTHROPIC_API_KEY` re-routes to the live default
(FIX-NA-1 emits `openrouter:auto`; FIX-GROK-1 repoints it to `grok:grok-4.3`).
One site subsumes all the literals AND auto-covers any new touchpoint upstream
adds; the literals can stay (harmless once rerouted). Companion **`anthropic-scan.sh`**
(+ `anthropic-allowlist.txt`) runs right after and **fails the build closed** if
the FIX-NA-1 sentinel is missing OR a native-anthropic client construction site
bypasses the chokepoint. Paired with `gbrain-loud-llm-failures.sh` (makes the
facts-extraction swallow LOUD) and the `gbrain-liveness` invariant for triple
coverage. **⚠️ On upgrade:** if gbrain moves the `resolveRecipe` anchor, the patch
fails the build — re-point it. `deprecate_when`: gbrain goes provider-agnostic /
adds a global route knob (the `still_needed_probe` checks this automatically).

### 2. `gbrain-mcp-tool-allowlist.sh` — curated MCP tool surface

**Why.** `gbrain serve --http` advertises all ~81 non-localOnly operations over
MCP and does **not** filter the tool list by OAuth scope (scope is enforced only
at *call* time — so reducing a connector's scope does NOT reduce its tool count).
gbrain ships no flag to expose a subset. An 81-tool surface bloats client context
and hurts tool selection.

**What it does.** Rewrites the one line in `serve-http.ts`
(`const mcpOperations = operations.filter(op => !op.localOnly)`) to also honor an
optional **`GBRAIN_MCP_TOOLS`** env allowlist (comma-separated op names, a Railway
service var). Unset = all tools (unchanged); set = only those tools are advertised
+ callable. **Change the exposed set anytime by editing the `GBRAIN_MCP_TOOLS`
Railway var — no rebuild needed for list changes** (only a rebuild re-applies the
source patch itself). Current curated set is ~18 retrieval-focused ops (search,
query, recall, think, get_page, list_pages, get_backlinks, get_links,
get_timeline, find_experts, traverse_graph, get_recent_salience, find_anomalies,
put_page, add_link, add_timeline_entry, get_stats, get_health). **⚠️ On upgrade**:
if gbrain moves the anchor line, this patch fails the build with
`[gbrain-mcp-allowlist] anchor not found` — re-point it in the script.

## For full deployment context

See `Venture-Formations/hermes-workspace`:

- `AGENTS.md` — deployment-wide overview
- `CHANGELOG.md` — every change since gbrain install
- `UPGRADING_GBRAIN.md` — Hermes/gbrain upgrade procedure
- `OPERATIONS_LOG.md` — infra history
