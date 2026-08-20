# Security Policy

## Supported Versions

The `quilt-base` project provides long-term support (LTS) for the most recent
major and minor release of every image variant. Older versions receive
critical security backports on a best-effort basis only.

| Variant    | Latest tag              | Supported           | EOL (planned) |
| ---------- | ----------------------- | ------------------- | ------------- |
| Alpine     | `alpine-latest`         | ✅ Yes              | T+12 months   |
| Ubuntu     | `ubuntu-latest`         | ✅ Yes              | T+24 months (Ubuntu LTS) |
| Distroless | `distroless-latest`     | ✅ Yes              | T+12 months   |
| Scratch    | `scratch-latest`        | ✅ Yes              | T+12 months   |

Where `T` is the date of the most recent LTS release for the upstream base
(Alpine 3.x, Ubuntu 24.04 LTS, distroless Debian 12).

A version is considered **supported** when it:
1. Receives weekly Dependabot and Trivy scans.
2. Is rebuilt by the auto-rebuild workflow within 7 days of an upstream
   patch release.
3. Has a non-EOL SBOM published as a GitHub release asset.

## Reporting a Vulnerability

**Please do not file public GitHub issues for security vulnerabilities.**

Use GitHub's private vulnerability disclosure:
👉 https://github.com/SuperInstance/quilt-base/security/advisories/new

If you cannot use the GitHub UI (e.g. the advisory is embargoed or the
issue is in a private mirror), email `security@superinstance.dev` with
the subject line `quilt-base vulnerability report`. The PGP fingerprint
for this address is published on
<https://github.com/SuperInstance/quilt-base/blob/main/SECURITY.md>.

### What to include

- The variant (`alpine`, `ubuntu`, `distroless`, `scratch`) and tag
  (e.g. `alpine-0.1.0`).
- A reproducer: `docker run ...` command or a minimal Dockerfile.
- The exact CVE ID, if one is published.
- Whether the vulnerability is in the base image itself or in a
  downstream Quilt agent that uses it.

### Response targets

| Severity | Initial response | Patch target   |
| -------- | ---------------- | -------------- |
| CRITICAL | ≤ 24 hours       | ≤ 72 hours     |
| HIGH     | ≤ 3 business days| ≤ 14 days      |
| MEDIUM   | ≤ 7 business days| ≤ 30 days      |
| LOW      | ≤ 30 days        | next quarterly |

"Initial response" means an acknowledgement that the report was received
and a preliminary assessment of severity.

"Patch target" means a new image tag published to GHCR. We aim to backport
to all supported LTS branches simultaneously.

## Security Architecture

`quilt-base` images are hardened in the following ways. This is a summary;
the actual controls are encoded in the Dockerfiles under `/docker` and the
scan scripts under `/security`.

### Defense in depth

1. **No setuid binaries.** All setuid bits are stripped in the final
   image. Even if a non-root attacker exploits a busybox applet, they
   cannot escalate to root.

2. **No package manager in the final image.** `apk`, `apt`, and `dpkg`
   are removed from the Alpine and Ubuntu variants at build time. There
   is nothing to use to install further packages at runtime.

3. **No shell in the distroless / scratch variants.** The published
   images have no `/bin/sh`, no `bash`, no `ash`. `docker exec` will
   fail unless the downstream agent adds a debug binary.

4. **Non-root default user.** The Alpine and Ubuntu images run as UID
   1000 (`quilt`) by default. The distroless image uses UID 65532
   (`nonroot`).

5. **Pinned CA bundle.** Each image has a `/etc/ssl/certs/ca-certificates.crt`
   that is the only CA bundle in the image. There is no fallback to
   `/etc/pki/tls` or `/usr/local/share/certs`.

6. **OCI labels.** Every image carries the standard
   `org.opencontainers.image.*` labels (creator, source, revision, etc.)
   so the supply chain is traceable.

7. **SBOMs.** Every release is published with both SPDX 2.3 and
   CycloneDX 1.5 SBOMs. They are available as workflow artifacts and as
   in-toto attestations via `cosign verify-attestation`.

### Continuous scanning

| Tool    | Frequency  | Failure mode                      |
| ------- | ---------- | --------------------------------- |
| Trivy   | Daily      | Opens a tracking issue + rebuilds |
| Grype   | Daily      | Posts to SARIF (best-effort)      |
| Dependabot | Weekly | Opens PR for upstream bumps       |
| Auto-rebuild | Weekly | Rolls forward to latest upstream  |

The full pipeline is in `.github/workflows/cve-scan.yml` and
`scripts/auto-rebuild.yml`.

### Known limitations

- **Alpine uses musl libc.** Some Node.js native modules (e.g.
  `bcrypt`) that depend on glibc semantics may not work. Use
  `quilt-base:ubuntu` for those.
- **Distroless has no shell.** Debugging requires a separate debug image
  (`gcr.io/distroless/static-debian12:debug`) or a `kubectl debug`
  session.
- **Scratch has no OS at all.** Your binary MUST be statically linked
  with musl (Rust: `--target x86_64-unknown-linux-musl`, Go:
  `CGO_ENABLED=0`, C: `-static`).

## Acknowledgements

Vulnerability reporters who follow this policy are credited (with their
permission) in the corresponding GitHub Security Advisory. Reporters
who find a CRITICAL or HIGH issue that is patched within the target SLA
are listed in the project's `CREDITS.md` and offered a Quilt t-shirt.

## Policy version

This policy is version `1.0.0` and is reviewed annually. Changes are
tracked in `SECURITY.md`'s git history.
