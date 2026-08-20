#!/usr/bin/env bash
# =============================================================================
# Quilt Base — Trivy CVE scanner
# =============================================================================
# Scans a built image (or image:tag) with Aqua Security's Trivy and exits
# non-zero if any HIGH or CRITICAL CVEs are present.
#
# Usage:
#   security/trivy-scan.sh <image:tag> [--report PATH] [--ignore-unfixed]
#
# Exit codes:
#   0  — clean (no HIGH/CRITICAL, or all vulns have a fix).
#   1  — HIGH or CRITICAL CVE with no available fix.
#   2  — Trivy itself failed (not installed, network error, etc.).
#
# This script is called by:
#   * `.github/workflows/cve-scan.yml`   — daily scan, posts to issues.
#   * `scripts/auto-rebuild.yml`         — gates auto-rebuild.
#   * `scripts/build-all.sh`             — gates the final push.
# =============================================================================

# -----------------------------------------------------------------------------
# Strict mode — fail fast on any unexpected error.
# -----------------------------------------------------------------------------
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# -----------------------------------------------------------------------------
# Defaults — overridable via CLI args.
# -----------------------------------------------------------------------------
IMAGE="${1:-}"
REPORT_PATH="${QUILT_TRIVY_REPORT:-/tmp/trivy-report.json}"
SEVERITY="HIGH,CRITICAL"
IGNORE_UNFIXED="false"
SCANNERS="vuln,misconfig,secret,license"
DB_REPOSITORY="public.ecr.aws/aquasecurity/trivy-db"
JAVA_DB_REPOSITORY="public.ecr.aws/aquasecurity/trivy-java-db"

# -----------------------------------------------------------------------------
# Logging — emit to stderr so stdout is reserved for Trivy's JSON when
# --report is not used.
# -----------------------------------------------------------------------------
log()   { printf '[trivy-scan] %s\n' "$*" >&2; }
fail()  { printf '[trivy-scan] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

# -----------------------------------------------------------------------------
# Argument parsing — minimal, explicit, no getopt.
# -----------------------------------------------------------------------------
if [[ -z "${IMAGE}" ]]; then
  cat >&2 <<'USAGE'
Usage: trivy-scan.sh <image:tag> [options]

Options:
  --report PATH         Write JSON report to PATH (default: /tmp/trivy-report.json)
  --severity LIST       Comma-separated severities (default: HIGH,CRITICAL)
  --ignore-unfixed      Do not flag vulns without a published fix
  --scanners LIST       Comma-separated scanners (default: vuln,misconfig,secret,license)

Environment:
  QUILT_TRIVY_REPORT    Override default --report path
  TRIVY_VERSION         Pinned Trivy version (default: 0.58.0)
  TRIVY_USERNAME        Optional registry username (private registries)
  TRIVY_PASSWORD        Optional registry password (private registries)
USAGE
  exit 2
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)         REPORT_PATH="$2"; shift 2 ;;
    --severity)       SEVERITY="$2"; shift 2 ;;
    --ignore-unfixed) IGNORE_UNFIXED="true"; shift ;;
    --scanners)       SCANNERS="$2"; shift 2 ;;
    -h|--help)        exec "$0" "" ;;
    *)                fail "unknown argument: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# Trivy installation check.
# -----------------------------------------------------------------------------
if ! command -v trivy >/dev/null 2>&1; then
  log "trivy not found in PATH; attempting install via official installer"
  TRIVY_VERSION="${TRIVY_VERSION:-0.58.0}"
  case "$(uname -sm)" in
    "Linux x86_64")  TRIVY_ARCH=Linux-64bit   ;;
    "Linux aarch64") TRIVY_ARCH=Linux-ARM64   ;;
    "Darwin x86_64") TRIVY_ARCH=macOS-64bit   ;;
    "Darwin arm64")  TRIVY_ARCH=macOS-ARM64   ;;
    *) fail "unsupported architecture: $(uname -sm)" 2 ;;
  esac
  curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${TRIVY_ARCH}.tar.gz" \
    | tar -xz -C /tmp trivy
  install -m 0755 /tmp/trivy /usr/local/bin/trivy
  log "trivy ${TRIVY_VERSION} installed"
fi

# -----------------------------------------------------------------------------
# Trivy version — print for log correlation.
# -----------------------------------------------------------------------------
log "scanning ${IMAGE} with trivy $(trivy --version | awk '/^Version/{print $2}')"

# -----------------------------------------------------------------------------
# Build the trivy command line.
# -----------------------------------------------------------------------------
TRIVY_ARGS=(
  image
  --severity "${SEVERITY}"
  --scanners "${SCANNERS}"
  --db-repository "${DB_REPOSITORY}"
  --java-db-repository "${JAVA_DB_REPOSITORY}"
  --format json
  --output "${REPORT_PATH}"
  --quiet
  --no-progress
)
if [[ "${IGNORE_UNFIXED}" == "true" ]]; then
  TRIVY_ARGS+=(--ignore-unfixed)
fi

# -----------------------------------------------------------------------------
# Run trivy. We capture the exit code separately because we want to
# distinguish "found vulns" (1) from "trivy itself errored" (>= 2).
# -----------------------------------------------------------------------------
set +e
trivy "${TRIVY_ARGS[@]}" "${IMAGE}"
TRIVY_RC=$?
set -e

case "${TRIVY_RC}" in
  0)
    log "CLEAN: no HIGH/CRITICAL vulnerabilities"
    exit 0
    ;;
  1)
    # Vulns found — summarize, then exit 1 so callers (CI, pre-push
    # hooks, build-all.sh) treat this as a build failure.
    log "FAIL: HIGH/CRITICAL vulnerabilities detected. See ${REPORT_PATH}"
    if command -v jq >/dev/null 2>&1; then
      jq -r '
        .Results[]?
        | .Vulnerabilities[]?
        | select(.Severity == "HIGH" or .Severity == "CRITICAL")
        | "  - [\(.Severity)] \(.VulnerabilityID) \(.PkgName)@\(.InstalledVersion) -> \(.FixedVersion // "(no fix yet)")  (\(.Title // .Description // "no description"))"
      ' "${REPORT_PATH}" >&2 || true
    else
      log "(install jq for a per-CVE breakdown; the JSON is at ${REPORT_PATH})"
    fi
    exit 1
    ;;
  *)
    fail "trivy exited with code ${TRIVY_RC} (scan failed)" 2
    ;;
esac
