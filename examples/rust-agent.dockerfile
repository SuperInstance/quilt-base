# =============================================================================
# Quilt Base — Example: Rust agent
# =============================================================================
# This Dockerfile shows the canonical way to layer a Rust agent on top of
# `quilt-base:alpine` (or `quilt-base:scratch` for the smallest possible
# image). It uses musl for a fully static binary.
#
# Build approach:
#   * Builder stage uses the official `rust:alpine` image (NOT quilt-base)
#     so we have the full Rust toolchain. The result of this stage is a
#     single static binary.
#   * Runtime stage is either:
#       - `quilt-base:alpine`   — convenience, has shell, can `docker exec`.
#       - `quilt-base:scratch`  — smallest possible (~4 MB final image).
#     We default to scratch below.
#
# To use it:
#   1. Replace `your-org/your-agent` with the real image name.
#   2. Replace `your-binary` with the name of your Cargo `[package].name`.
#   3. `docker build -t your-org/your-agent:latest .`
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 — Build (full Rust toolchain on Alpine)
# -----------------------------------------------------------------------------
# Pin the toolchain so a stray `rustup update` in CI does not invalidate
# the entire build cache. Use the same Alpine major version as quilt-base.
# -----------------------------------------------------------------------------
FROM rust:1.82-alpine3.19 AS builder

# Heavy header: builder stage.

# musl-tools provides the static C library + linker. build-base pulls
# in gcc, make, etc. for C dependencies in the dependency graph.
RUN apk add --no-cache \
        musl-dev \
        musl-tools \
        build-base \
        pkgconfig \
        openssl-dev \
        openssl-libs-static \
        ca-certificates \
    && update-ca-certificates

# Tell cargo to target musl explicitly. This is a no-op on the alpine
# toolchain (it defaults to musl) but makes the intent unambiguous.
ENV CC_x86_64_unknown_linux_musl="musl-gcc" \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER="musl-gcc" \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUNNER="env -i"

# Use the SQLX_OFFLINE / cargo-chef pattern (commented) for fastest
# incremental builds. If your project doesn't use SQLx, the naive COPY
# below is fine.

WORKDIR /build

# ---- OPTION A: naive (no caching of dependencies) ----
# COPY . .
# RUN cargo build --release --target x86_64-unknown-linux-musl

# ---- OPTION B: cargo-chef (recommended for larger projects) ----
# FROM rust:1.82-alpine3.19 AS chef
# RUN cargo install cargo-chef
# WORKDIR /build
#
# FROM chef AS planner
# COPY . .
# RUN cargo chef prepare --recipe-path recipe.json
#
# FROM chef AS builder
# COPY --from=planner /build/recipe.json recipe.json
# RUN cargo chef cook --release --target x86_64-unknown-linux-musl --recipe-path recipe.json
# COPY . .
# RUN cargo build --release --target x86_64-unknown-linux-musl

# For this template, we use Option A but structure it so a maintainer
# can switch to Option B by uncommenting the planner/builder stages
# above and changing the `COPY . .` + `RUN cargo build` lines below.
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY benches ./benches
COPY tests ./tests

# Strip + LTO + size opt. We target musl so the resulting binary is
# fully static and works in `quilt-base:scratch`.
RUN cargo build \
        --release \
        --target x86_64-unknown-linux-musl \
        --locked \
    && strip target/x86_64-unknown-linux-musl/release/your-binary \
    && ls -lh target/x86_64-unknown-linux-musl/release/your-binary

# -----------------------------------------------------------------------------
# Stage 2 — Runtime (scratch + static binary)
# -----------------------------------------------------------------------------
# We use `quilt-base:scratch` because the binary is fully static. Switch
# to `quilt-base:alpine` if you need a shell for debugging.
# -----------------------------------------------------------------------------
FROM ghcr.io/SuperInstance/quilt-base:scratch

# Heavy header: published layer.
LABEL org.opencontainers.image.title="your-agent" \
      org.opencontainers.image.description="Example Rust agent on quilt-base" \
      org.opencontainers.image.licenses="Apache-2.0" \
      io.quilt.agent.runtime="rust" \
      io.quilt.agent.runtime_version="1.82" \
      io.quilt.agent.target="x86_64-unknown-linux-musl"

# Pull the static binary out of the builder.
COPY --from=builder /build/target/x86_64-unknown-linux-musl/release/your-binary /quilt/bin/agent

# The base image already has ca-certificates, /etc/passwd, and
# timezone data. If your agent uses TLS, no further setup is needed.

# A small set of standard env vars.
ENV QUILT_AGENT_HOME=/quilt \
    QUILT_AGENT_LOG_LEVEL=info \
    QUILT_AGENT_PORT=8080 \
    RUST_LOG=info \
    RUST_BACKTRACE=1

# Healthcheck: `--no-progress` keeps wget quiet; `-q` is implicit.
# If your agent doesn't ship wget, replace with a tiny Rust binary that
# probes its own /healthz. The base image has none.
# HEALTHCHECK NONE  # uncomment to disable

# Expose the canonical Quilt agent HTTP port.
EXPOSE 8080

# The binary is the entrypoint. The base image's ENTRYPOINT is tini; we
# override it. If your agent is not a good PID 1 (e.g. doesn't handle
# SIGTERM), wrap it with tini here too.
# ENTRYPOINT ["/sbin/tini", "--"]
# CMD ["/quilt/bin/agent"]
ENTRYPOINT ["/quilt/bin/agent"]
CMD []
