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
ARG HERMES_REF=fix/parallel-tool-calls-v2026.5.29.2

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
RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/${HERMES_REPO}.git /opt/hermes-agent && \
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
# Current: v0.42.34.0 — master @ 2026-06-08, commit 099d9a8. To upgrade: set
# GBRAIN_REF to the new master sha, push this branch, then run `gbrain
# post-upgrade` + verify-upgrade.sh on the container (UPGRADING_GBRAIN.md §0).
ARG GBRAIN_REF=099d9a8f5505f1d64e4f4f784f8429cc2d47c18f
RUN curl -fsSL https://bun.sh/install | bash && \
    bun install -g github:garrytan/gbrain#${GBRAIN_REF} && \
    # Smoke check — fail the build loudly if the gbrain ref is unresolvable
    # (Step 1: "gbrain --version should print a version number").
    gbrain --version

# --- VF gbrain CORE patch: route hardcoded `anthropic:` model defaults -> OpenRouter
# gbrain hardcodes native `anthropic:` model strings as the default for ~8 LLM
# touchpoints (fact-dedup classifier, page synopsis, contextual-retrieval, takes
# bootstrap, contradiction judge, brainstorm, propose/grade takes, gateway
# chat/expansion). This deployment has only OPENROUTER_API_KEY + OPENAI_API_KEY
# (no Anthropic key), so those paths throw inside chat() and are swallowed
# silently (facts/takes return []/continue; fact-dedup degrades to cosine).
# Setting `models.default`/`chat_model` only fixes config-backed paths; these
# literals have no config knob, so we rewrite them to OpenRouter-routed
# equivalents (same model + tier). This is the ONE place we modify gbrain CORE
# (documented exception to the "never modify gbrain core" rule — see CLAUDE.md).
# Re-applied on every rebuild so it survives GBRAIN_REF bumps; the post-patch
# `gbrain --version` fails the build loudly if the patched tree won't load.
# ⚠️ VALIDATE ON EVERY UPGRADE: gbrain may rename a model id / add a new
# hardcoded touchpoint — the script's audit must report 0 leftovers (see
# UPGRADING_GBRAIN.md). Idempotent + safe to re-run.
COPY patches/ /app/patches/
RUN bash /app/patches/gbrain-openrouter-model-defaults.sh && \
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
