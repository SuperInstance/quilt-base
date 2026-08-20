# =============================================================================
# Quilt Base — Example: Node.js / TypeScript agent
# =============================================================================
# This Dockerfile shows the canonical way to layer a TypeScript agent on
# top of `quilt-base:alpine`. It:
#   * Uses multi-stage build (builder → runtime) so the final image
#     does not contain `node-gyp`, `gcc`, devDependencies, or test code.
#   * Runs as the unprivileged `quilt` user created by the base image.
#   * Sets `NODE_ENV=production` so npm/yarn/pnpm skip devDependencies.
#   * Uses `npm ci` (deterministic) instead of `npm install`.
#   * Caches `node_modules` separately from `dist/` so `docker build`
#     cache invalidation only happens when `package*.json` changes.
#
# To use it:
#   1. Copy this file to your agent repo as `Dockerfile`.
#   2. Replace `your-org/your-agent` with the real image name.
#   3. `docker build -t your-org/your-agent:latest .`
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 — Build (full toolchain available)
# -----------------------------------------------------------------------------
# Pull the Alpine variant of quilt-base as the builder. This gives us
# npm + nodejs + ca-certificates + tini, plus the `quilt` user (UID 1000).
# -----------------------------------------------------------------------------
FROM ghcr.io/SuperInstance/quilt-base:alpine AS builder

# Heavy header: builder stage.
ARG NODE_ENV=production
ENV NODE_ENV=${NODE_ENV} \
    NPM_CONFIG_LOGLEVEL=warn \
    NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /build

# Copy lockfile + manifests first to leverage Docker layer cache. When
# only source files change, the `npm ci` step is skipped entirely.
COPY package.json package-lock.json* ./
COPY --chown=quilt:quilt . .

# Install all dependencies (including dev — needed for `tsc`).
# `npm ci` requires package-lock.json; if your project uses pnpm or yarn
# swap the install command.
RUN npm ci --no-audit --no-fund --include=dev

# Build TypeScript. The exact command depends on your `package.json`
# `scripts.build` field. Adjust the path to match.
RUN npm run build

# Strip dev dependencies for the final image. We install with
# `production=true` to get a clean `node_modules` without rebuilding
# native modules.
RUN npm prune --omit=dev

# -----------------------------------------------------------------------------
# Stage 2 — Runtime (slim, no toolchain)
# -----------------------------------------------------------------------------
# Re-use the same quilt-base for runtime. No `node-gyp`, no `gcc`.
# -----------------------------------------------------------------------------
FROM ghcr.io/SuperInstance/quilt-base:alpine AS runtime

# Heavy header: published layer.
LABEL org.opencontainers.image.title="your-agent" \
      org.opencontainers.image.description="Example TypeScript agent on quilt-base" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.quilt.agent.runtime="nodejs" \
      io.quilt.agent.runtime_version="20"

# Re-declare production-only env.
ENV NODE_ENV=production \
    NODE_OPTIONS="--enable-source-maps" \
    PATH=/quilt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Copy the built output and pruned node_modules. The `--chown` is
# critical: without it, the `quilt` user can't read the files.
COPY --from=builder --chown=quilt:quilt /build/dist         /home/quilt/work/dist
COPY --from=builder --chown=quilt:quilt /build/node_modules  /home/quilt/work/node_modules
COPY --from=builder --chown=quilt:quilt /build/package.json   /home/quilt/work/package.json

# A pre-baked set of common Quilt runtime environment variables.
ENV QUILT_AGENT_HOME=/home/quilt/work \
    QUILT_AGENT_LOG_LEVEL=info \
    QUILT_AGENT_PORT=8080

# Healthcheck: hit a /healthz endpoint that the agent is expected to
# expose. The base image ships /bin/true; we override.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://127.0.0.1:${QUILT_AGENT_PORT}/healthz \
        || exit 1

# Expose the canonical Quilt agent HTTP port.
EXPOSE 8080

# Default working directory.
WORKDIR /home/quilt/work

# Run as the unprivileged `quilt` user (UID 1000) created by the base.
USER quilt:quilt

# tini is the base image's ENTRYPOINT; we just specify what tini runs.
# In this example, the compiled JS is at /home/quilt/work/dist/index.js.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "/home/quilt/work/dist/index.js"]
