#!/usr/bin/env bash
# =============================================================================
# Quilt Base — Build all variants and push to GHCR
# =============================================================================
# Builds every Quilt base image variant in parallel, tags each with
#   - the version (from `git describe --tags` or QUILT_BASE_VERSION env)
#   - the date (YYYY-MM-DD)
#   - the git SHA
#   - "latest" (only for the most recent successful build)
# then scans each with Trivy and Grype, and pushes to GitHub Container
# Registry (GHCR) at ghcr.io/SuperInstance/quilt-base.
#
# Usage:
#   scripts/build-all.sh [variant]  — build only one variant
#   scripts/build-all.sh            — build all
#   scripts/build-all.sh --no-push  — build & scan, but do not push
#   scripts/build-all.sh --no-scan  — build & push, skip CVE scan
#
# Environment:
#   GITHUB_REPOSITORY       — used to derive GHCR org (default: SuperInstance/quilt-base)
#   GITHUB_TOKEN            — GHCR auth token; required for push
#   QUILT_BASE_VERSION      — version tag (default: derived from git)
#   QUILT_PUSH              — "true" to push, anything else to skip (default: true)
#   BUILDX_BUILDER          — name of an existing buildx builder (optional)
#   PLATFORMS               — comma list (default: linux/amd64,linux/arm64)
# =============================================================================

# -----------------------------------------------------------------------------
# Strict mode
# -----------------------------------------------------------------------------
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-SuperInstance/quilt-base}"
GHCR_REGISTRY="ghcr.io"
IMAGE_BASE="${GHCR_REGISTRY}/${GITHUB_REPOSITORY,,}"
QUILT_PUSH="${QUILT_PUSH:-true}"
QUILT_SCAN="${QUILT_SCAN:-true}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
ONLY_VARIANT=""
USE_BUILDX_CACHE="${USE_BUILDX_CACHE:-true}"

# -----------------------------------------------------------------------------
# Variants — keep in lockstep with /docker/Dockerfile.* filenames.
# -----------------------------------------------------------------------------
VARIANTS=(alpine ubuntu distroless scratch)

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log()  { printf '[build-all] %s\n' "$*" >&2; }
fail() { printf '[build-all] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push)            QUILT_PUSH="false"; shift ;;
    --no-scan)            QUILT_SCAN="false"; shift ;;
    --variant)            ONLY_VARIANT="$2"; shift 2 ;;
    --platforms)          PLATFORMS="$2"; shift 2 ;;
    --no-buildkit-cache)  USE_BUILDX_CACHE="false"; shift ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      # First positional = variant name
      if [[ -z "${ONLY_VARIANT}" ]] && [[ " ${VARIANTS[*]} " == *" $1 "* ]]; then
        ONLY_VARIANT="$1"
        shift
      else
        fail "unknown argument: $1"
      fi
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Version resolution — git describe, with a sane fallback.
# -----------------------------------------------------------------------------
resolve_version() {
  if [[ -n "${QUILT_BASE_VERSION:-}" ]]; then
    printf '%s' "${QUILT_BASE_VERSION}"
    return
  fi
  if command -v git >/dev/null 2>&1 && [[ -d "${REPO_ROOT}/.git" ]]; then
    git -C "${REPO_ROOT}" describe --tags --always --dirty 2>/dev/null \
      || git -C "${REPO_ROOT}" rev-parse --short HEAD
  else
    printf '0.1.0'
  fi
}

VERSION="$(resolve_version)"
DATE_TAG="$(date -u +%Y%m%d)"
GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

log "version=${VERSION}  date=${DATE_TAG}  sha=${GIT_SHA}"
log "image base: ${IMAGE_BASE}"
log "platforms:  ${PLATFORMS}"
log "push:       ${QUILT_PUSH}"
log "scan:       ${QUILT_SCAN}"

# -----------------------------------------------------------------------------
# buildx setup — use a persistent builder for cache reuse.
# -----------------------------------------------------------------------------
BUILDER_NAME="${BUILDX_BUILDER:-quilt-base-builder}"
if [[ "${USE_BUILDX_CACHE}" == "true" ]]; then
  if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    log "creating buildx builder ${BUILDER_NAME}"
    docker buildx create \
      --name "${BUILDER_NAME}" \
      --driver docker-container \
      --bootstrap \
      --platform "${PLATFORMS}" >/dev/null
  fi
  docker buildx use "${BUILDER_NAME}"
fi

# -----------------------------------------------------------------------------
# GHCR login — only required for push, but cheap to attempt.
# -----------------------------------------------------------------------------
if [[ "${QUILT_PUSH}" == "true" ]]; then
  if [[ -z "${GITHUB_TOKEN:-}" ]] && [[ -z "${GHCR_TOKEN:-}" ]]; then
    fail "GITHUB_TOKEN (or GHCR_TOKEN) is required for push; set it in the environment"
  fi
  printf '%s' "${GITHUB_TOKEN:-${GHCR_TOKEN}}" \
    | docker login "${GHCR_REGISTRY}" -u "${GITHUB_ACTOR:-SuperInstance}" --password-stdin
fi

# -----------------------------------------------------------------------------
# Build a single variant. Emits the list of tags it pushed to stdout.
# -----------------------------------------------------------------------------
build_variant() {
  local variant="$1"
  local dockerfile="${REPO_ROOT}/docker/Dockerfile.${variant}"

  if [[ ! -f "${dockerfile}" ]]; then
    log "SKIP ${variant}: no Dockerfile at ${dockerfile}"
    return 0
  fi

  log "=== building variant: ${variant} ==="

  local tags=(
    --tag "${IMAGE_BASE}:${variant}-${VERSION}"
    --tag "${IMAGE_BASE}:${variant}-${DATE_TAG}"
    --tag "${IMAGE_BASE}:${variant}-${GIT_SHA}"
  )
  if [[ "${variant}" == "alpine" ]]; then
    # The Alpine image is the "default" Quilt base, so it also gets the
    # untagged latest tag and the bare :VERSION tag.
    tags+=(
      --tag "${IMAGE_BASE}:latest"
      --tag "${IMAGE_BASE}:${VERSION}"
    )
  fi

  local cache_args=()
  if [[ "${USE_BUILDX_CACHE}" == "true" ]]; then
    cache_args+=(
      --cache-from "type=registry,ref=${IMAGE_BASE}:buildcache-${variant}"
      --cache-to   "type=registry,ref=${IMAGE_BASE}:buildcache-${variant},mode=max"
    )
  fi

  local build_args=(
    --platform "${PLATFORMS}"
    --file "${dockerfile}"
    --label "io.quilt.base.build_date=${DATE_TAG}"
    --label "io.quilt.base.vcs_ref=${GIT_SHA}"
    --label "io.quilt.base.version=${VERSION}"
    --build-arg "QUILT_BASE_VERSION=${VERSION}"
    --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    --build-arg "VCS_REF=${GIT_SHA}"
    --build-arg "VCS_URL=https://github.com/${GITHUB_REPOSITORY}"
  )

  if [[ "${QUILT_PUSH}" == "true" ]]; then
    build_args+=(--push)
  else
    build_args+=(--load)
  fi

  docker buildx build "${build_args[@]}" "${cache_args[@]}" "${tags[@]}" "${REPO_ROOT}"
  printf '%s\n' "${IMAGE_BASE}:${variant}-${VERSION}"
}

export -f build_variant log
export IMAGE_BASE DATE_TAG GIT_SHA PLATFORMS QUILT_PUSH REPO_ROOT GITHUB_REPOSITORY USE_BUILDX_CACHE

# -----------------------------------------------------------------------------
# Parallel build — one variant per CPU, max 4 at once.
# -----------------------------------------------------------------------------
if [[ -n "${ONLY_VARIANT}" ]]; then
  BUILT="$(build_variant "${ONLY_VARIANT}")"
  BUILT_VARIANTS=("${ONLY_VARIANT}")
else
  log "building ${#VARIANTS[@]} variants in parallel"
  # xargs is portable; -P limits concurrency; -I{} passes variant name.
  BUILT="$(printf '%s\n' "${VARIANTS[@]}" \
    | xargs -n 1 -P 4 -I {} bash -c 'build_variant "$@"' _ {})"
  BUILT_VARIANTS=("${VARIANTS[@]}")
fi

# -----------------------------------------------------------------------------
# CVE scan each built image. We use the `variant-VERSION` tag (the
# immutable one) so reruns are reproducible.
# -----------------------------------------------------------------------------
if [[ "${QUILT_SCAN}" == "true" ]]; then
  log "=== running CVE scan on each built image ==="
  SCAN_FAILED=()
  for variant in "${BUILT_VARIANTS[@]}"; do
    local_tag="${IMAGE_BASE}:${variant}-${VERSION}"
    log "scanning ${local_tag}"
    if ! "${REPO_ROOT}/security/trivy-scan.sh" "${local_tag}"; then
      SCAN_FAILED+=("${local_tag}")
    fi
    # Grype is best-effort; if it's not installed, do not fail the build.
    if command -v grype >/dev/null 2>&1; then
      "${REPO_ROOT}/security/grype-scan.sh" "${local_tag}" || true
    fi
  done
  if [[ ${#SCAN_FAILED[@]} -gt 0 ]]; then
    fail "CVE scan FAILED for: ${SCAN_FAILED[*]}"
  fi
fi

# -----------------------------------------------------------------------------
# SBOM generation for each variant.
# -----------------------------------------------------------------------------
if [[ -f "${REPO_ROOT}/scripts/sbom-generate.sh" ]]; then
  log "=== generating SBOMs ==="
  for variant in "${BUILT_VARIANTS[@]}"; do
    "${REPO_ROOT}/scripts/sbom-generate.sh" "${IMAGE_BASE}:${variant}-${VERSION}" || true
  done
fi

log "=== DONE ==="
printf '%s\n' "${BUILT}"
