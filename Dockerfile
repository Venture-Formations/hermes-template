FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Which hermes-agent revision to install. Accepts any git ref the upstream
# repo publishes — a release tag (recommended for reproducibility) or a
# branch name (`main`) for bleeding edge.
#
# This deployment pulls from Venture-Formations/hermes-agent (a fork of
# NousResearch/hermes-agent) so we can carry the parallel_tool_calls fix
# branch on top of upstream v2026.5.16 until it merges upstream. To revert
# to vanilla upstream, change HERMES_REPO back to NousResearch/hermes-agent
# and HERMES_REF to a tag from https://github.com/NousResearch/hermes-agent/releases.
ARG HERMES_REPO=Venture-Formations/hermes-agent
ARG HERMES_REF=fix/parallel-tool-calls-v2026.6.5

# tini = tiny init that we run as PID 1. Without it, hermes's grandchild
# processes (MCP stdio servers, git, bun, browser daemons spawned by tools)
# reparent to PID 1 when their parents exit and pile up as zombies. After
# weeks of uptime that exhausts the kernel's PID table → "fork: cannot
# allocate memory" and the container dies. tini reaps zombies in the
# background and forwards SIGTERM/SIGINT to our entrypoint so Railway's
# stop signal still triggers our graceful shutdown. Standard container init
# (same as Docker's `--init` flag and Kubernetes' pause container).
#
# Node.js is required only at build time to compile the Hermes React dashboard.
# We strip the source + apt lists afterwards to keep the image lean.
# unzip is required by the Bun installer (curl https://bun.sh/install | bash)
# used below for the gbrain bake — the slim base image does not ship it.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git tini unzip && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install hermes-agent (provides the `hermes` CLI) and pre-build its React
# dashboard so `hermes dashboard` has nothing to build at runtime.
#
# [all] in v2026.5.16: cron, cli, dev, pty, mcp, homeassistant, sms, acp,
# google, web, youtube. Messaging platforms, TTS, and other heavy backends
# are now lazy-installed by hermes at first use. We pre-install the ones
# this template actually uses so first-message latency is instant.
# When bumping HERMES_REF, re-check hermes-agent's pyproject.toml [all] and
# the extras below against the new release's pyproject.toml.
#
# HERMES_FORK_REV: cache-bust for fork-CONTENT changes pushed to the SAME
# HERMES_REF branch. Docker keys the clone layer on the RUN text + ARG values, so
# a push to the fork branch tip (HERMES_REF unchanged) would otherwise reuse the
# CACHED clone = stale fork code. Bump this when the fork branch tip changes
# without a HERMES_REF rename. (Bumped to 3 for VF-FAIL-CLOSED-1 early guard, fork @cbe090e52.)
ARG HERMES_FORK_REV=3
RUN echo "hermes-agent fork rev ${HERMES_FORK_REV} (HERMES_REF=${HERMES_REF})" && \
    git clone --depth 1 --branch ${HERMES_REF} https://github.com/${HERMES_REPO}.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv pip install --system --no-cache -e ".[all,messaging,tts-premium,honcho,bedrock,anthropic,edge-tts,hindsight]" && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    cd /opt/hermes-agent/ui-tui && \
    npm install --silent --no-fund --no-audit --progress=false && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /opt/hermes-agent/.git /root/.npm

# Why pre-build ui-tui (and why we don't delete it after):
# - The dashboard's embedded Chat tab spawns `node ui-tui/dist/entry.js`
#   on every WebSocket connect to /api/pty.
# - Without HERMES_TUI_DIR, hermes's _make_tui_argv falls through to the
#   npm install + build path (since git-editable installs don't have the
#   bundled tui_dist/ that PyPI wheels include), adding 30-60s to the
#   first chat-open and blocking the asyncio event loop.
# - Pre-building at image time surfaces build failures here rather than
#   at user request time, and makes first-chat-open instant.
# - We keep ui-tui/ entirely (node_modules + dist + src) so HERMES_TUI_DIR
#   can point at it (see below).

# --- gbrain binary durability (image-baked) ------------------------------
# Canonical install path: gbrain is a Bun + TypeScript runtime, so Bun is a
# hard prerequisite and the only supported global-install mechanism is
# `bun install -g github:garrytan/gbrain`.
#   - INSTALL_FOR_AGENTS.md Step 1 (github.com/garrytan/gbrain @ master):
#       curl -fsSL https://bun.sh/install | bash
#       export PATH="$HOME/.bun/bin:$PATH"
#       bun install -g github:garrytan/gbrain
#   - docs/operations/headless-install.md Pattern 1 ("RUN bun install -g
#       github:garrytan/gbrain") — the supported Docker/CI install.
#
# We bake it into the image rather than installing at runtime so the binary
# survives every Railway deploy (the old /opt/bun/bin assumption put gbrain
# on an ephemeral path that vanished on rebuild). Bun installs to a stable,
# world-readable prefix (/usr/local/bun) via BUN_INSTALL so PATH resolution
# is deterministic regardless of $HOME.
ENV BUN_INSTALL=/usr/local/bun
ENV PATH="/usr/local/bun/bin:$PATH"
# gbrain ships via master (no GitHub release tags), so we pin a specific master
# commit for reproducible builds. Bumping this ARG also busts Docker's layer
# cache for the install below, forcing a fresh pull on upgrade.
# Current: v0.42.42.0 — master @ 2026-06-12, commit 4ee530f (the no-anthropic
# reroute + scan below were authored & validated against this tree; all 12 core
# patches re-validated STILL-NEEDED against this ref via still_needed_probe).
# To upgrade: set GBRAIN_REF to the new master sha, push this branch, then run
# `gbrain post-upgrade` + verify-upgrade.sh on the container (UPGRADING_GBRAIN.md §0).
ARG GBRAIN_REF=4ee530f3c545b880cecc47c4f877e0ed014896b4
RUN curl -fsSL https://bun.sh/install | bash && \
    bun install -g github:garrytan/gbrain#${GBRAIN_REF} && \
    # Smoke check — fail the build loudly if the gbrain ref is unresolvable
    # (Step 1: "gbrain --version should print a version number").
    gbrain --version

# --- VF gbrain CORE patch: no-native-anthropic reroute (FIX-NA-1) ----------
# This deployment provisions NO ANTHROPIC_API_KEY (operator: never a native
# Anthropic dependency; OpenRouter may still route to Claude, billed via
# OPENROUTER_API_KEY). gbrain hardcodes native `anthropic:` model defaults at
# dozens of touchpoints with no global config knob; any that reach a native
# anthropic recipe throw inside gateway.chat() and are swallowed silently
# (facts/takes return []/continue) → the brain silently produces 0 facts.
#
# REPLACES the old literal-rewrite patch (gbrain-openrouter-model-defaults.sh),
# which chased ~20 literals across a dozen files and could not keep up with a
# release-less master (a new touchpoint in an unmatched shape = a fresh silent
# zero). gbrain resolves EVERY model string through one chokepoint —
# resolveRecipe()/parseModelId() in model-resolver.ts — so we inject a single
# no-key reroute there: native `anthropic:` → openrouter:auto. One site subsumes
# all the literals AND auto-covers any new touchpoint upstream adds.
#
# anthropic-scan.sh then PROVES the guarantee fail-closed (FIX-NA-1 sentinel
# present + no un-allowlisted native-anthropic client construction bypasses the
# chokepoint). Both run after the gbrain install; re-applied on every GBRAIN_REF
# bump; idempotent. The reroute FAILS THE BUILD LOUDLY (old container keeps
# serving) if its anchor moved — never a silent no-op. See UPGRADING_GBRAIN.md.
COPY patches/ /app/patches/
RUN bash /app/patches/gbrain-no-anthropic-reroute.sh && \
    bash /app/patches/anthropic-scan.sh && \
    gbrain --version

# --- VF gbrain CORE patch: grok recipe + FIX-NA-1 repoint (FIX-GROK-1) ------
# Routes the gbrain knowledge engine's LLM calls through the operator's grok /
# SuperGrok subscription via the Hermes xAI-OAuth proxy instead of openrouter.
# (a) writes a KEYLESS openai-compat `grok` recipe (src/core/ai/recipes/grok.ts,
# base_url http://127.0.0.1:8645/v1 — the localhost proxy supervised in start.sh,
# which strips the inbound Authorization and attaches the operator's xAI OAuth);
# (b) registers it in the static recipes/index.ts registry; (c) REPOINTS the
# FIX-NA-1 reroute target openrouter:auto -> grok:grok-4.3 at the single
# resolveRecipe chokepoint, so gbrain's hardcoded native `anthropic:` defaults
# AND a bare grok-4.3 (both normalize to the no-key native path) route to grok.
# MUST run AFTER gbrain-no-anthropic-reroute.sh (it repoints that patch's emitted
# literal) and after anthropic-scan.sh (which asserts only the sentinel, not the
# target, so the repoint does not disturb it). The recipe + its consumer (the
# reroute) are ONE atomic unit with one smoke gate, so the recipe always exists
# before anything routes to it. Idempotent; FAILS THE BUILD LOUDLY (old container
# keeps serving) if an anchor moved. Embeddings stay on zeroentropyai. See
# patches/gbrain-grok-recipe.meta.yml + UPGRADING_GBRAIN.md.
RUN bash /app/patches/gbrain-grok-recipe.sh && \
    gbrain --version

# --- VF gbrain CORE patch: grok budget unmetered (FIX-GROK-BUDGET-1) --------
# The grok recipe above is keyless/flat-rate (operator SuperGrok OAuth via the
# Hermes proxy), so grok:grok-4.3 is intentionally absent from gbrain's pricing
# maps. gbrain's BudgetTracker hard-fails ("TX2 no_pricing") on any --max-cost-
# capped call whose model is unpriced — which makes `gbrain brainstorm`
# (orchestrator forces maxCostUsd ?? 5; CLI rejects --max-cost 0, no bypass)
# unusable on grok, and would break any future capped phase routed to grok. This
# patch adds 'grok' to a FREE_SUBSCRIPTION_CHAT_PROVIDERS $0 allowlist in
# budget-tracker.ts lookupPricing() — mirroring gbrain's own FREE_LOCAL_* sets —
# so the cap is satisfied at $0 while paid providers stay priced and the
# orchestrator's own token-volume guards stay live. Runs after the grok recipe
# (logical grouping; no hard dependency — different file). Idempotent; FAILS THE
# BUILD LOUDLY if an anchor moved. See patches/gbrain-grok-budget-unmetered.meta.yml.
RUN bash /app/patches/gbrain-grok-budget-unmetered.sh && \
    gbrain --version

# --- VF gbrain CORE patch #2: curated MCP tool allowlist -------------------
# `gbrain serve --http` advertises all ~81 non-localOnly operations over MCP and
# does NOT filter the tool list by OAuth scope (scope is enforced only at call
# time), and gbrain ships no flag to expose a subset. This patch makes serve
# honor an optional GBRAIN_MCP_TOOLS env allowlist (comma-separated op names),
# so the exposed tool surface is controlled at runtime via a Railway service var
# (unset = all tools; set = just those). Trims client context + improves tool
# selection. SECOND (and final) documented exception to "never modify gbrain
# core" — see CLAUDE.md. ⚠️ VALIDATE ON EVERY UPGRADE: the patch anchors on the
# `operations.filter(op => !op.localOnly)` line in serve-http.ts; if gbrain moves
# it the script EXITS NON-ZERO and FAILS THE BUILD (old container keeps serving)
# so the anchor gets re-pointed. See UPGRADING_GBRAIN.md. Idempotent.
RUN bash /app/patches/gbrain-mcp-tool-allowlist.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-timeline-bullet-hyphen-split (FIX-TL-3) --------------
# Timeline bullet parser: require spaced em/en dash separator (stop splitting slugs on bare hyphens). Idempotent + self-auditing: EXITS NON-ZERO and FAILS THE BUILD
# (old container keeps serving) if its anchor moves. See patches/gbrain-timeline-bullet-hyphen-split.meta.yml.
RUN bash /app/patches/gbrain-timeline-bullet-hyphen-split.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-enrich-skill-fidelity (FIX-EN-1/2) --------------
# enrich skill: preserve sharpest verbatim claim + enforced contradiction/stance reconciliation. Idempotent + self-auditing: EXITS NON-ZERO and FAILS THE BUILD
# (old container keeps serving) if its anchor moves. See patches/gbrain-enrich-skill-fidelity.meta.yml.
RUN bash /app/patches/gbrain-enrich-skill-fidelity.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-source-pages-mentions-only (FIX-TE-2) --------------
# link inference: type:source pages emit 'mentions' only (no false works_at/founded/invested_in). Idempotent + self-auditing: EXITS NON-ZERO and FAILS THE BUILD
# (old container keeps serving) if its anchor moves. See patches/gbrain-source-pages-mentions-only.meta.yml.
RUN bash /app/patches/gbrain-source-pages-mentions-only.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-enrich-cli-prompt-twin (FIX-EN-3) --------------
# CLI enrich prompt twin of EN-1/2 (protective-only; cycle.enrich_thin default OFF). Idempotent + self-auditing: EXITS NON-ZERO and FAILS THE BUILD
# (old container keeps serving) if its anchor moves. See patches/gbrain-enrich-cli-prompt-twin.meta.yml.
RUN bash /app/patches/gbrain-enrich-cli-prompt-twin.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-link-type-endpoint-gate (FIX-TE-1) --------------
# inferLinkType endpoint gate: *->person never typed; company->company founded -> mentions. MUST run after TE-2. Self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old container
# keeps serving) if an anchor moves. See patches/gbrain-link-type-endpoint-gate.meta.yml.
RUN bash /app/patches/gbrain-link-type-endpoint-gate.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-timeline-writer-fixes (FIX-TL-1/2/4) --------------
# timeline date from source published_at; back-edges -> ## Mentions; ## Timeline sorted DESC. MUST run after TL-3. Self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old container
# keeps serving) if an anchor moves. See patches/gbrain-timeline-writer-fixes.meta.yml.
RUN bash /app/patches/gbrain-timeline-writer-fixes.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-takes-notable-claims (FIX-TK-2) --------------------
# Render graded takes as ## Takes fences onto the entity pages a reader sees: adds
# writeTakesToFence (Part A), mines source/person/company pages (Part B), routes each
# take to the entity it's about + attributes the speaker (Part C). Surfaces the takes
# the v0.42 pipeline already produces (bootstrap_enabled=true) but that died DB-only.
# Self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old container keeps serving) if an
# anchor moves. See patches/gbrain-takes-notable-claims.meta.yml.
RUN bash /app/patches/gbrain-takes-notable-claims.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-takes-classifier-quality (FIX-TQC-1) -------
# CLASSIFIER_SYSTEM (the LLM take-extraction prompt, extract-takes-from-pages.ts)
# lacked kind-conservatism, weight-magnitude guidance, and named-trivia exclusion
# (the 3 dims the takes-quality rubric penalizes). Folds the judge's guidance into
# the prompt. ORDERED AFTER FIX-TK-2 (same file; FIX-TK-2 consumes the batch flush
# / ALLOWED_PAGE_TYPES / loop, NOT the prompt literal — anchors do not overlap).
# Governs only the ~11% LLM-extracted path (ALLOWED_PAGE_TYPES); the 99% fence
# path (FIX-TK-2) is unaffected. Idempotent + self-auditing: FAILS THE BUILD (old
# container keeps serving) on anchor drift. See gbrain-takes-classifier-quality.meta.yml.
RUN bash /app/patches/gbrain-takes-classifier-quality.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-takes-extract-frontier (FIX-TKF-1) ---------
# extractTakesFromPages selected eligible pages with NO already-has-takes filter,
# so every run re-LLMs the same top-N pages (write-idempotent via FIX-TK-2 fence
# dedup, but NOT cost-idempotent → re-burns the shared xAI grok proxy). Adds
# `AND NOT EXISTS (... takes ...)` so a run only classifies zero-take pages —
# the prerequisite that makes the gbrain-takes-drain cron safe (drains the
# post-06-08 backlog + forward inflow at ~$0 steady state). Edits the QUERY, not
# the prompt or FIX-TK-2's splice — ordered after FIX-TK-2 + FIX-TQC-1 (same file,
# non-overlapping anchors). Idempotent + self-auditing: FAILS THE BUILD (old
# container keeps serving) on anchor drift. See gbrain-takes-extract-frontier.meta.yml.
RUN bash /app/patches/gbrain-takes-extract-frontier.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-loud-llm-failures (FIX-LF-1) --------------
# Make silently-swallowed LLM/gateway failures LOUD in facts extraction — the
# audit's silent-zero "Face 2" (a chat-unavailable / swallowed chat() throw
# becomes `return []` with no log, so a config-store split looks identical to an
# empty corpus). Logs a tagged [VF-FIX-LF-1] line on each silent-return path; no
# control-flow change. Self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old
# container keeps serving) if an anchor moved. See gbrain-loud-llm-failures.meta.yml.
RUN bash /app/patches/gbrain-loud-llm-failures.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-subagent-no-native-anthropic (FIX-NA-2) ---
# Close the ONE native-Anthropic path FIX-NA-1 does not cover: the subagent LLM
# loop builds its client DIRECTLY (`makeAnthropic = deps.makeAnthropic ?? (() =>
# new Anthropic())`), NOT through resolveRecipe — so on this no-ANTHROPIC_API_KEY
# deployment that default would reach the Anthropic API directly, bypassing the
# no-native guarantee. Minimal safe hardening: when no key is set the default
# factory THROWS a tagged ERR_NATIVE_ANTHROPIC_BLOCKED [VF-FIX-NA-2] (loud, named
# for review) instead of silently constructing a native client; with a key (or an
# explicit deps.makeAnthropic) behavior is unchanged. Does NOT re-architect the
# loop through the gateway (the upstream deprecate_when). This replaces the prior
# anthropic-allowlist.txt entry for subagent.ts (now patched, not allowlisted).
# Self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old container keeps serving)
# if its anchor moved. See patches/gbrain-subagent-no-native-anthropic.meta.yml.
RUN bash /app/patches/gbrain-subagent-no-native-anthropic.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-propose-takes-disable (FIX-PT-2) ----------
# Add the missing `cycle.propose_takes.enabled` gate (DEFAULT-OFF) to gbrain's
# dream/autopilot cycle. The propose_takes phase runs every tick but is upstream-
# broken: no consumer/review CLI (GH #1467) + no negative-result cache so it re-
# LLMs every zero-take page (~$100/wk, GH #2106), and — unlike skillopt /
# conversation_facts_backfill — it has NO enable gate. This patch wraps the phase
# in a default-OFF gate (absent key => phase skipped), so it stays off across
# rebuilds AND a DB reset, reversible with
# `gbrain config set cycle.propose_takes.enabled true`. This INVERTS the upstream
# default (on) by design. Self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old
# container keeps serving) if its anchor moved. See gbrain-propose-takes-disable.meta.yml.
RUN bash /app/patches/gbrain-propose-takes-disable.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-takes-grade-sort-asc (FIX-TK-3) -----------
# Flip the grade_takes since_date sort DESC→ASC (oldest-first) in BOTH engines.
# grade_takes loads listTakes({sortBy:'since_date', limit:50}) and its own comment
# says "oldest-first", but the engines order since_date DESC (newest-first), so the
# 50-take window only ever holds the newest (too-recent) takes → 0 verdicts every
# cycle, starving take_grade_cache / calibration_profiles / dream_verdicts / eval.
# grade-takes.ts is the SOLE sortBy:'since_date' caller, so the flip is safe and
# realises the documented intent (pairs with the gbrain-backfill-take-dates cron
# that supplies the dates). Self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old
# container keeps serving) if the since_date ORDER BY moved. See
# gbrain-takes-grade-sort-asc.meta.yml.
RUN bash /app/patches/gbrain-takes-grade-sort-asc.sh && \
    gbrain --version

# --- VF gbrain CORE patch: schema-pack extends/borrow merge (C+B) -----------
# ONE patch (the "C+B" audit outcome): fix #1749 — resolvePack built the
# ResolvedPack from the BARE CHILD, so a custom pack `extends: gbrain-base-v2`
# collapsed to its own types and the bundled lens meta-packs never composed
# borrow_from (#1838). The inheritance engine lives ENTIRELY in resolvePack,
# and the CONFIG-ACTIVATION path (DB/tier `cfg.schema_pack` → defaultPackLocator
# → resolvePack) exercises the merge IDENTICALLY to `schema use`. So feeding the
# MERGED manifest into resolvePack's consumers is the only change gbrain needs.
#
# The two former companion patches were DROPPED under C+B (proven unnecessary
# for the config-activation path — see UPGRADING_GBRAIN.md "C+B refactor"):
#   • #1750 (loader.ts js-yaml block-scalar) — accepted DX loss: custom packs
#     must use a SINGLE-LINE `description:` (no `|` block).
#   • #1574/#1726 (bundled-SSOT for `schema use/list`) — accepted DX loss:
#     activate a custom/lens pack via `gbrain config set schema_pack <name>`,
#     NOT `schema use` (which prints "Unknown pack" for non-{base,recommended}
#     names); `schema list` shows 2 not 7. Resolution is unaffected.
#
# This patch is an ANCHOR-SPLICE of registry.ts (not a full-file replace):
# anchored on the self-documenting "v0.41+ T20 follow-up" comment + a
# match-count assertion (each of the 3 substitutions must apply exactly once),
# so it can NEVER silently no-op. Idempotent + self-auditing: EXITS NON-ZERO
# and FAILS THE BUILD (old container keeps serving) on anchor drift / a
# zero-or-multi match. See patches/gbrain-schema-pack-resolve-merge.meta.yml.
RUN bash /app/patches/gbrain-schema-pack-resolve-merge.sh && \
    gbrain --version

# --- VF gbrain CORE patch: extract_atoms drain no-progress guard (FIX-AD-1) --
# runExtractAtomsDrain's per-batch break is gated on
# `r.extracted === 0 && r.skipped === 0`, but session_corpus_dir re-discovers
# transcript duplicates so r.skipped is ~always > 0 → the break NEVER fires and a
# 0-atom no-transcript page spins ~20 empty Haiku batches per run until the
# wallclock window times out (pure LLM waste; atom output is otherwise healthy).
# This re-bases the break on REAL forward progress (extracted===0 AND the
# remaining backlog did not drop vs the prior iteration), reusing the loop's
# existing `const before = await deps.countRemaining()` read. Idempotent +
# self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old container keeps serving)
# on anchor drift. See patches/gbrain-atom-drain-progress-guard.meta.yml.
RUN bash /app/patches/gbrain-atom-drain-progress-guard.sh && \
    gbrain --version

# --- gbrain core patch: cross-modal eval default route (FIX-CME-1) ----------
# `gbrain eval cross-modal` defaults its 3 scoring slots to native providers
# (A=openai:gpt-4o, B=anthropic:claude-opus-4-7, C=google:gemini-1.5-pro); only
# slot B reroutes to grok ($0) via FIX-NA-1, so a DEFAULT run bills the native
# OPENAI_API_KEY (slot A) + Google key (slot C). The command is operator-only
# (not cron-wired), but the default must be billing-safe. This re-points all 3
# DEFAULT_SLOTS ids to DISTINCT anthropic ids (all reroute to grok via FIX-NA-1,
# $0) while leaving the --slot-a/b/c-model overrides intact for deliberate native
# diversity. Idempotent + self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old
# container keeps serving) on anchor drift. See
# patches/gbrain-cross-modal-eval-default-route.meta.yml.
RUN bash /app/patches/gbrain-cross-modal-eval-default-route.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-eval-takes-quality-gateway-env (FIX-TQ-1) --
# `gbrain eval takes-quality run` (our weekly gbrain-eval-takes-quality-weekly
# cron) self-configures the gateway with `configureGateway({ ...cfg,
# ...(process.env) } as any)` — spreading process.env as TOP-LEVEL keys, which
# leaves the REQUIRED AIGatewayConfig.env field undefined (the `as any` hid the
# type error). Every model call then throws `undefined is not an object
# (evaluating 'env[k]')` in defaultResolveAuth → 0/3 slots score → verdict
# INCONCLUSIVE → exit 2 → the weekly cron fails EVERY run and take-quality is
# never measured. This nests env under the `env:` key (mirrors the working
# eval-cross-modal.ts pattern). A vanilla gbrain bug (filed upstream), not VF-
# specific. Idempotent + self-auditing: EXITS NON-ZERO and FAILS THE BUILD (old
# container keeps serving) on anchor drift. See
# patches/gbrain-eval-takes-quality-gateway-env.meta.yml.
RUN bash /app/patches/gbrain-eval-takes-quality-gateway-env.sh && \
    gbrain --version

# --- VF gbrain CORE patch: gbrain-takes-quality-eval-meter (FIX-TQM-1) -------
# The takes-quality eval METER was broken: (P2) DEFAULT_MODEL_PANEL defaulted to
# openai:gpt-4o + anthropic + google:gemini-1.5-pro, so a bare run got <2 grok
# successes -> INCONCLUSIVE and billed native OpenAI/Google keys; (P1) the eval
# sampler had no `WHERE active` filter so it scored struck/superseded rows every
# other reader excludes. Repoints the default panel to 3 anthropic ids (all grok,
# $0, real PASS/FAIL) and adds the active filter to both sampler branches. Pure
# read-path/config; zero brain mutation. Validated live (bare run INCONCLUSIVE ->
# FAIL 6.3, 3/3 models). Idempotent + self-auditing: FAILS THE BUILD on anchor
# drift. See gbrain-takes-quality-eval-meter.meta.yml.
RUN bash /app/patches/gbrain-takes-quality-eval-meter.sh && \
    gbrain --version

# --- youtube-playlist-sync collector deps (yt-dlp + ffmpeg) ----------------
# The workspace `youtube-playlist-sync` skill (hourly `youtube-playlist-sync`
# cron) shells out to yt-dlp (caption + audio download) and ffmpeg (Whisper-
# fallback audio chunking). Its preflight (`skills/youtube-playlist-sync/
# script.ts` requireTool over ["yt-dlp","ffmpeg","git"]) hard-fails the cron if
# either is missing — the dashboard symptom is
# "Script exited with code 1 stderr: [fatal] Required tool not found on PATH: yt-dlp".
# The slim base ships neither, so bake them into the image (durable across
# Railway rebuilds — same rationale as the gbrain bake above). yt-dlp via uv to
# the --system prefix (latest: YouTube changes break stale builds); ffmpeg via apt.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg && \
    rm -rf /var/lib/apt/lists/* && \
    uv pip install --system --no-cache yt-dlp && \
    # Smoke check — fail the build loudly if either tool is unresolvable,
    # mirroring the gbrain --version gate above.
    yt-dlp --version && ffmpeg -version | head -1

COPY requirements.txt /app/requirements.txt
RUN uv pip install --system --no-cache -r /app/requirements.txt

RUN mkdir -p /data/.hermes

COPY server.py /app/server.py
COPY templates/ /app/templates/
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes

# Points hermes at our pre-built TUI bundle. hermes's _make_tui_argv checks
# HERMES_TUI_DIR first: if dist/entry.js exists there, it skips the npm
# install/build entirely. This is the official packager path (Nix uses it too)
# and avoids the 30-60s npm bootstrap that git-editable installs would otherwise
# trigger on first /chat connection.
ENV HERMES_TUI_DIR=/opt/hermes-agent/ui-tui

# tini wraps start.sh so it runs as PID 1's child instead of as PID 1 itself.
# `-g` propagates signals to the whole process group so `docker stop` /
# Railway's SIGTERM cleanly terminates the entire tree, not just start.sh.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]
