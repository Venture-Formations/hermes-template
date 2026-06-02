# CLAUDE.md — hermes-template (fork)

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
ARG HERMES_REF=fix/parallel-tool-calls-v2026.5.28
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
  baked for the `youtube-playlist-sync` cron), plus the **gbrain core
  model-default patch** (`COPY patches/` + `RUN bash
  patches/gbrain-openrouter-model-defaults.sh` right after the bake — see
  "gbrain core patch" below).
- **`patches/gbrain-openrouter-model-defaults.sh`** — the **only place VF
  modifies gbrain CORE**. Rewrites gbrain's hardcoded native `anthropic:`
  model defaults (~8 LLM touchpoints) to OpenRouter-routed equivalents so the
  brain runs on `OPENROUTER_API_KEY` (we have no `ANTHROPIC_API_KEY`). Applied
  at build time, re-applied on every `GBRAIN_REF` bump. **⚠️ must be
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
- Autopilot self-supervises (it forks/restarts the Minions worker), so no
  external watchdog cron is needed.

## gbrain core patch — `patches/gbrain-openrouter-model-defaults.sh`

**This is the ONLY place VF modifies gbrain core.** The "never modify gbrain
core" rule (hermes-workspace `CLAUDE.md`) has this one documented exception.

**Why.** A gbrain model string's provider prefix selects the API key:
`anthropic:claude-haiku-4-5` → Anthropic API (`ANTHROPIC_API_KEY`);
`openrouter:anthropic/claude-haiku-4.5` → OpenRouter (`OPENROUTER_API_KEY`) —
same model. This deployment has **only** `OPENROUTER_API_KEY` + `OPENAI_API_KEY`
(no Anthropic key). gbrain hardcodes native `anthropic:` strings as the default
for ~8 LLM touchpoints that have **no config knob** (fact-dedup classifier,
page synopsis, contextual-retrieval, `takes extract --from-pages`, contradiction
judge, brainstorm, propose/grade takes, gateway chat/expansion defaults). Those
paths throw inside `chat()` and are swallowed silently — facts/takes extractors
return `[]`, fact-dedup degrades to `cosine_fallback`. Setting
`models.default`/`chat_model` (in `/data/.gbrain/config.json`) only fixes the
config-backed paths; the patch rewrites the hardcoded literals to their
OpenRouter equivalents (haiku→haiku, sonnet→sonnet) so the whole brain runs on
the OpenRouter key.

**How it's applied.** Build-time `RUN` in the `Dockerfile` immediately after the
gbrain bake, so it's baked into the image and re-applied on every `GBRAIN_REF`
bump. The post-patch `gbrain --version` fails the build loudly if the patched
tree won't load. The script is idempotent and also safe to run on a live
container (the canonical recovery if a rebuild ever lands without the patch:
`bash /app/patches/gbrain-openrouter-model-defaults.sh`).

**⚠️ VALIDATE ON EVERY gbrain UPGRADE.** gbrain may rename a model id, move a
default, or add a new hardcoded `anthropic:` touchpoint. The script's post-patch
audit must report **0 remaining native-anthropic model defaults**. If non-zero,
add the new literal to the `apply` list in the script. This is a required step
in `UPGRADING_GBRAIN.md`. (The native `anthropic:messages` rate-limit key is
intentionally NOT a model — it must stay untouched.)

**Related runtime config (on the `/data` volume, survives rebuilds — NOT part of
the patch but part of the same OpenRouter-only setup):**
`/data/.gbrain/config.json` carries `chat_model` + `expansion_model` =
`openrouter:anthropic/claude-haiku-4.5` and the DB config store carries
`models.default = openrouter:auto`. The lone remaining native-Anthropic
dependency is the prompt-cache `subagent_capability` WARN (only gbrain's native
`anthropic` recipe sets `supports_prompt_cache:true`) — benign, deferred.

## For full deployment context

See `Venture-Formations/hermes-workspace`:

- `CLAUDE.md` — deployment-wide overview
- `CHANGELOG.md` — every change since gbrain install
- `UPGRADING_GBRAIN.md` — Hermes/gbrain upgrade procedure
- `OPERATIONS_LOG.md` — infra history
