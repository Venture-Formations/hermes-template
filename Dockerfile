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
RUN curl -fsSL https://bun.sh/install | bash && \
    bun install -g github:garrytan/gbrain && \
    # Smoke check — fail the build loudly if the gbrain ref is unresolvable
    # (Step 1: "gbrain --version should print a version number").
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
