#!/usr/bin/env bash
# =============================================================================
# Quilt Base — SBOM generator
# =============================================================================
# Generates a Software Bill of Materials for each Quilt base image using
# Anchore's Syft. We emit two formats:
#   * SPDX 2.3 JSON   — for compliance / legal review
#   * CycloneDX 1.5 JSON — for security tooling / dependency-track
#
# SBOMs are uploaded as workflow artifacts by `.github/workflows/build.yml`
# and also attached as OCI image attestations via `cosign attest`.
#
# Usage:
#   scripts/sbom-generate.sh <image:tag> [--output-dir DIR]
#
# Exit codes:
#   0 — success
#   1 — syft or cosign failed
#   2 — invalid usage
# =============================================================================

# -----------------------------------------------------------------------------
# Strict mode
# -----------------------------------------------------------------------------
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
IMAGE="${1:-}"
OUTPUT_DIR="${QUILT_SBOM_DIR:-./sbom}"
SYFT_VERSION="${SYFT_VERSION:-1.4.0}"
COSIGN_VERSION="${COSIGN_VERSION:-2.4.1}"
ATTEST="${QUILT_SBOM_ATTEST:-false}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log()  { printf '[sbom-gen] %s\n' "$*" >&2; }
fail() { printf '[sbom-gen] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
if [[ -z "${IMAGE}" ]]; then
  cat >&2 <<'USAGE'
Usage: sbom-generate.sh <image:tag> [--output-dir DIR] [--attest]

Options:
  --output-dir DIR   Write SBOMs to DIR (default: ./sbom)
  --attest           Also create a cosign attestation against the image
                     (requires COSIGN_EXPERIMENTAL=1 and registry auth)

Environment:
  QUILT_SBOM_DIR     Override default --output-dir
  SYFT_VERSION       Pinned Syft version (default: 1.4.0)
  COSIGN_VERSION     Pinned cosign version (default: 2.4.1)
  COSIGN_EXPERIMENTAL Set to 1 to enable cosign attestations
USAGE
  exit 2
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --attest)     ATTEST="true"; shift ;;
    -h|--help)    exec "$0" "" ;;
    *)            fail "unknown argument: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# Syft installation
# -----------------------------------------------------------------------------
if ! command -v syft >/dev/null 2>&1; then
  log "syft not found; installing v${SYFT_VERSION}"
  case "$(uname -sm)" in
    "Linux x86_64")  SYFT_ARCH=linux-amd64 ;;
    "Linux aarch64") SYFT_ARCH=linux-arm64 ;;
    "Darwin x86_64") SYFT_ARCH=macos-amd64 ;;
    "Darwin arm64")  SYFT_ARCH=macos-arm64 ;;
    *) fail "unsupported architecture: $(uname -sm)" 2 ;;
  esac
  curl -fsSL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_${SYFT_ARCH}.tar.gz" \
    | tar -xz -C /tmp syft
  install -m 0755 /tmp/syft /usr/local/bin/syft
  log "syft ${SYFT_VERSION} installed"
fi

# -----------------------------------------------------------------------------
# Output setup
# -----------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"
SAFE_TAG="$(printf '%s' "${IMAGE}" | tr '/:@' '---')"
SPDX_PATH="${OUTPUT_DIR}/${SAFE_TAG}.spdx.json"
CDX_PATH="${OUTPUT_DIR}/${SAFE_TAG}.cdx.json"

log "generating SPDX 2.3 SBOM for ${IMAGE} -> ${SPDX_PATH}"
syft "registry:${IMAGE}" \
  --output "spdx-json=${SPDX_PATH}" \
  --source-name "quilt-base" \
  --source-version "${QUILT_BASE_VERSION:-0.1.0}" \
  --quiet

log "generating CycloneDX 1.5 SBOM for ${IMAGE} -> ${CDX_PATH}"
syft "registry:${IMAGE}" \
  --output "cyclonedx-json=${CDX_PATH}" \
  --source-name "quilt-base" \
  --source-version "${QUILT_BASE_VERSION:-0.1.0}" \
  --quiet

# -----------------------------------------------------------------------------
# cosign attestation (optional)
#
# If COSIGN_EXPERIMENTAL=1 and `--attest` was passed, attach the SPDX
# SBOM to the image as an in-toto attestation. This makes the SBOM
# discoverable from `cosign verify-attestation`.
# -----------------------------------------------------------------------------
if [[ "${ATTEST}" == "true" ]] && [[ "${COSIGN_EXPERIMENTAL:-0}" == "1" ]]; then
  if ! command -v cosign >/dev/null 2>&1; then
    log "cosign not found; installing v${COSIGN_VERSION}"
    case "$(uname -sm)" in
      "Linux x86_64")  COSIGN_ARCH=linux-amd64 ;;
      "Linux aarch64") COSIGN_ARCH=linux-arm64 ;;
      "Darwin x86_64") COSIGN_ARCH=macos-amd64 ;;
      "Darwin arm64")  COSIGN_ARCH=macos-arm64 ;;
      *) fail "unsupported architecture for cosign: $(uname -sm)" 2 ;;
    esac
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-${COSIGN_ARCH}" \
      -o /usr/local/bin/cosign
    chmod 0755 /usr/local/bin/cosign
    log "cosign ${COSIGN_VERSION} installed"
  fi

  log "attesting SPDX SBOM to ${IMAGE}"
  cosign attest --yes --predicate "${SPDX_PATH}" --type spdx "registry:${IMAGE}"
  log "attesting CycloneDX SBOM to ${IMAGE}"
  cosign attest --yes --predicate "${CDX_PATH}" --type cyclonedx "registry:${IMAGE}"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
log "done"
printf 'spdx=%s\n'  "${SPDX_PATH}"  >&2
printf 'cdx=%s\n'   "${CDX_PATH}"   >&2
printf '%s\n%s\n'  "${SPDX_PATH}"  "${CDX_PATH}"
