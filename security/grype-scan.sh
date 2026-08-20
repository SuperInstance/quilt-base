#!/usr/bin/env bash
# =============================================================================
# Quilt Base — Grype CVE scanner
# =============================================================================
# Scans a built image (or image:tag) with Anchore's Grype and exits
# non-zero if any HIGH or CRITICAL CVEs are present. Grype uses the same
# vulnerability database format as Syft (which we also use for SBOM
# generation in `scripts/sbom-generate.sh`), so a Grype scan is the
# natural follow-up to producing an SBOM.
#
# Usage:
#   security/grype-scan.sh <image:tag> [--report PATH] [--ignore-unfixed]
#
# Exit codes:
#   0  — clean
#   1  — HIGH or CRITICAL CVE with no available fix
#   2  — Grype itself failed
#
# Grype is a useful complement to Trivy because:
#   * It uses a different vulnerability feed (Anchore's), so an issue
#     missed by Trivy is often caught by Grype and vice versa.
#   * It supports scanning a Syft SBOM directly without re-pulling
#     image layers (`grype sbom:./sbom.spdx.json`).
#   * It produces SARIF natively for GitHub code-scanning integration.
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
REPORT_PATH="${QUILT_GRYPE_REPORT:-/tmp/grype-report.json}"
SEVERITY="high,critical"
IGNORE_UNFIXED="false"
FAIL_ON="high,critical"
ONLY_FIXED="false"
DB_PROVIDER="anchore"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log()  { printf '[grype-scan] %s\n' "$*" >&2; }
fail() { printf '[grype-scan] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
if [[ -z "${IMAGE}" ]]; then
  cat >&2 <<'USAGE'
Usage: grype-scan.sh <image:tag> [options]

Options:
  --report PATH         Write JSON report to PATH (default: /tmp/grype-report.json)
  --severity LIST       Comma-separated severities to scan for (default: high,critical)
  --fail-on LIST        Comma-separated severities that cause non-zero exit
  --ignore-unfixed      Do not flag vulns without a published fix
  --only-fixed          Only consider vulns that have a fix available
  --db-provider NAME    Vulnerability DB provider (default: anchore)

Environment:
  QUILT_GRYPE_REPORT    Override default --report path
  GRYPE_VERSION         Pinned Grype version (default: 0.78.0)
USAGE
  exit 2
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)         REPORT_PATH="$2"; shift 2 ;;
    --severity)       SEVERITY="$2"; shift 2 ;;
    --fail-on)        FAIL_ON="$2"; shift 2 ;;
    --ignore-unfixed) IGNORE_UNFIXED="true"; shift ;;
    --only-fixed)     ONLY_FIXED="true"; shift ;;
    --db-provider)    DB_PROVIDER="$2"; shift 2 ;;
    -h|--help)        exec "$0" "" ;;
    *)                fail "unknown argument: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# Grype installation check
# -----------------------------------------------------------------------------
if ! command -v grype >/dev/null 2>&1; then
  log "grype not found in PATH; attempting install via official installer"
  GRYPE_VERSION="${GRYPE_VERSION:-0.78.0}"
  curl -fsSL "https://raw.githubusercontent.com/anchore/grype/main/install.sh" \
    | bash -s -- -b /usr/local/bin "v${GRYPE_VERSION}"
  log "grype ${GRYPE_VERSION} installed"
fi

# -----------------------------------------------------------------------------
# Version log
# -----------------------------------------------------------------------------
log "scanning ${IMAGE} with grype $(grype version | awk '/^Version:/{print $2}')"

# -----------------------------------------------------------------------------
# Build command. Grype's `registry:auth` mechanism lets us transparently
# authenticate to GHCR if GRYPE_REGISTRY_AUTH_FILE is set.
# -----------------------------------------------------------------------------
GRYPE_ARGS=(
  --severity "${SEVERITY}"
  --fail-on "${FAIL_ON}"
  --db-provider "${DB_PROVIDER}"
  --output json
  --file "${REPORT_PATH}"
  --quiet
)
if [[ "${IGNORE_UNFIXED}" == "true" ]]; then
  GRYPE_ARGS+=(--ignore-unfixed)
fi
if [[ "${ONLY_FIXED}" == "true" ]]; then
  GRYPE_ARGS+=(--only-fixed)
fi

# -----------------------------------------------------------------------------
# Run grype. The same exit-code trick as trivy-scan.sh.
# -----------------------------------------------------------------------------
set +e
grype "docker:${IMAGE}" "${GRYPE_ARGS[@]}"
GRYPE_RC=$?
set -e

case "${GRYPE_RC}" in
  0)
    log "CLEAN: no HIGH/CRITICAL vulnerabilities"
    exit 0
    ;;
  1)
    log "FAIL: HIGH/CRITICAL vulnerabilities detected. See ${REPORT_PATH}"
    if command -v jq >/dev/null 2>&1; then
      jq -r '
        .matches[]
        | select(.vulnerability.severity == "High" or .vulnerability.severity == "Critical")
        | "  - [\(.vulnerability.severity)] \(.vulnerability.id) \(.artifact.name)@\(.artifact.version) -> \(.vulnerability.fix.versions // [] | join(",") // "(no fix yet)")"
      ' "${REPORT_PATH}" >&2 || true
    else
      log "(install jq for a per-CVE breakdown; the JSON is at ${REPORT_PATH})"
    fi
    exit 1
    ;;
  *)
    fail "grype exited with code ${GRYPE_RC} (scan failed)" 2
    ;;
esac
