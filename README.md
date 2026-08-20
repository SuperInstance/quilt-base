<!--
  =============================================================================
  Quilt Base — README.md
  =============================================================================
  This is the public-facing landing page for the quilt-base repository. It is
  optimized for both human readers and GitHub's OCI / package registry page
  renderers. Heavy section dividers and explicit ASCII art make it easy to
  read in plain text (e.g. `gh repo view SuperInstance/quilt-base`).
  =============================================================================
-->

# 🧵 Quilt Base

```
    ██████╗ ██╗   ██╗██╗██╗  ████████╗
   ██╔═══██╗██║   ██║██║██║  ╚══██╔══╝
   ██║   ██║██║   ██║██║██║     ██║
   ██║▄▄ ██║██║   ██║██║██║     ██║
   ╚██████╔╝╚██████╔╝██║███████╗██║
    ╚══▀▀═╝  ╚═════╝ ╚═╝╚══════╝╚═╝
       B A S E   I M A G E S
  ────────────────────────────────
   minimal · hardened · zero-CVE
  ────────────────────────────────
```

> The foundation every Quilt agent stands on. Four variants. ~52 MB
> of total disk footprint. Zero unpatched CVEs at release time.

---

## 📖 Table of Contents

- [Mission](#-mission)
- [Quick Start](#-quick-start)
- [Image Variants](#-image-variants)
- [Image Sizes](#-image-sizes)
- [Security Scanning](#-security-scanning)
- [Auto-Rebuild Policy](#-auto-rebuild-policy)
- [Usage in the Quilt Ecosystem](#-usage-in-the-quilt-ecosystem)
- [SBOMs & Attestations](#-sboms--attestations)
- [Building Locally](#-building-locally)
- [Versioning & Tags](#-versioning--tags)
- [Contributing](#-contributing)
- [License](#-license)
- [Cross-References](#-cross-references)

---

## 🎯 Mission

`quilt-base` provides the **minimal, hardened, CVE-free base container
images** for the entire [Quilt agent ecosystem](https://github.com/SuperInstance).

The three non-negotiable properties of every image we ship:

1. **Minimal** — only the binaries needed to run a Quilt agent. No
   package manager, no shell, no docs, no setuid binaries.
2. **Hardened** — no shell in distroless/scratch, no setuid, no
   `sudo`, runs as a non-root user by default.
3. **Zero-CVE** — every release is scanned with Trivy and Grype.
   HIGH/CRITICAL with no available fix block the release.

We do not ship "kitchen sink" images. If you need a database client,
a language runtime, or a build toolchain, layer it on top — we provide
the foundation, you build the rest.

---

## 🚀 Quick Start

```bash
# Pull the default (Alpine) variant.
docker pull ghcr.io/SuperInstance/quilt-base:alpine-latest

# Run a long-lived agent container.
docker run --rm -it \
  --name my-quilt-agent \
  -p 8080:8080 \
  ghcr.io/SuperInstance/quilt-base:alpine-latest

# Or grab the distroless variant for production.
docker pull ghcr.io/SuperInstance/quilt-base:distroless-latest

# Or the absolute minimum — scratch + your static binary.
docker pull ghcr.io/SuperInstance/quilt-base:scratch-latest
```

> **Tip:** if you want the Ubuntu variant, use
> `ghcr.io/SuperInstance/quilt-base:ubuntu-latest`. The full
> tag matrix is in [Versioning & Tags](#-versioning--tags) below.

---

## 🎨 Image Variants

| Variant    | Base                                    | Use it when…                                                |
| ---------- | --------------------------------------- | ----------------------------------------------------------- |
| `alpine`   | `alpine:3.19` + Node.js 20 + tini       | You're building a TypeScript/JS agent or a small Go binary. |
| `ubuntu`   | `ubuntu:24.04` LTS + glibc + Node.js    | You need glibc, a long LTS window, or compliance-mandated Debian. |
| `distroless` | `gcr.io/distroless/static-debian12`   | You ship a static binary and want NO shell, NO package manager. |
| `scratch`  | Empty (no OS)                           | You have a single statically-linked binary and want ~4 MB.  |

`alpine` is the **default** Quilt base; it carries the `latest` tag. The
other three are specialized — pick them on purpose.

---

## 📦 Image Sizes

Target sizes (uncompressed, amd64):

| Variant    | Target | Typical (last 7 builds) | Notes                                 |
| ---------- | ------ | ------------------------ | ------------------------------------- |
| `alpine`   | 8 MB   | 7.4 – 8.2 MB             | tini + ca-certs + nodejs (optional)   |
| `ubuntu`   | 28 MB  | 26 – 31 MB               | apt removed; glibc kept                |
| `distroless` | 12 MB | 11 – 14 MB              | No shell, no package manager           |
| `scratch`  | 4 MB   | 3.6 – 4.4 MB             | Just your binary + CA bundle + TZ data |

`docker images ghcr.io/SuperInstance/quilt-base` after a pull will show
the actual on-disk size; the column above is the **uncompressed layer
size** reported by `docker buildx imagetools inspect`.

> **Why not smaller?** We could shave 1–2 MB off `alpine` by removing
> `nodejs` and `npm`. We don't, because every Quilt TypeScript agent
> needs them, and pulling Node.js as a separate layer would *grow* the
> total disk footprint for users.

---

## 🛡️ Security Scanning

Every image is scanned with **two** independent CVE databases on every
build. Either of them can fail a release.

### Trivy (Aqua Security)

```bash
./security/trivy-scan.sh ghcr.io/SuperInstance/quilt-base:alpine-latest
```

Trivy checks:
- OS packages (Alpine `apk`, Ubuntu `dpkg`, distroless `manifest.json`)
- Language dependencies (npm, pip, gem, etc.) discovered via Syft
- Misconfigurations (Dockerfile lint)
- Secret material accidentally COPY'd in
- License compliance

It exits non-zero on any HIGH/CRITICAL with no available fix. The CI
calls this script on every push and on a daily schedule.

### Grype (Anchore)

```bash
./security/grype-scan.sh ghcr.io/SuperInstance/quilt-base:alpine-latest
```

Grype uses a different vulnerability feed than Trivy, so a clean
Trivy scan does not imply a clean Grype scan. We use both for defense
in depth; Grype also produces SARIF directly for GitHub code-scanning
integration.

### Running both locally

```bash
# Convenience wrapper (defined in scripts/build-all.sh).
./scripts/build-all.sh --variant alpine --no-push
./security/trivy-scan.sh  ghcr.io/SuperInstance/quilt-base:alpine-$(git describe --tags)
./security/grype-scan.sh  ghcr.io/SuperInstance/quilt-base:alpine-$(git describe --tags)
```

---

## 🔄 Auto-Rebuild Policy

The auto-rebuild workflow (`.github/workflows/auto-rebuild.yml` via
`scripts/auto-rebuild.yml`) runs **weekly** on Monday at 06:00 UTC and:

1. Re-resolves the digest of every upstream base image (`alpine:3.19`,
   `ubuntu:24.04`, `gcr.io/distroless/static-debian12:nonroot`).
2. If any digest changed, triggers the `build.yml` matrix to rebuild
   every variant on amd64 + arm64.
3. Scans every freshly built image with Trivy and Grype.
4. Generates SPDX 2.3 + CycloneDX 1.5 SBOMs and attaches them as
   in-toto attestations.
5. Pushes the new tags to `ghcr.io/SuperInstance/quilt-base` and opens
   a PR pinning the new digests in the rest of the Quilt org.

A separate **daily** workflow (`.github/workflows/cve-scan.yml`) runs
Trivy + Grype against the latest published tags. If a CVE appears
post-release, it:
- Opens (or appends to) a tracking issue.
- Fires a `repository_dispatch` event to trigger an out-of-band rebuild.
- Posts a SARIF result to GitHub code-scanning.

**The Net result:** any CVE in `alpine`, `ubuntu`, or `distroless` is
patched and re-published within **at most 7 days** of upstream fix
release. Typically much faster — the weekly pipeline usually catches
it within 24 hours.

---

## 🌐 Usage in the Quilt Ecosystem

Every Quilt agent that runs as a container extends one of these four
images. Drop-in examples are in `/examples`:

- `examples/node-agent.dockerfile` — TypeScript agent on `alpine`.
- `examples/rust-agent.dockerfile` — Rust agent on `scratch` (or `alpine`).

For a quick `FROM` reference:

| Quilt agent repo              | FROM line                                                    |
| ----------------------------- | ------------------------------------------------------------ |
| `quilt-agent`                 | `ghcr.io/SuperInstance/quilt-base:alpine`                    |
| `quilt-worker`                | `ghcr.io/SuperInstance/quilt-base:alpine`                    |
| `quilt-elf`                   | `ghcr.io/SuperInstance/quilt-base:scratch`                   |
| `quilt-pincher`               | `ghcr.io/SuperInstance/quilt-base:distroless`                |
| `quilt-fleet`                 | `ghcr.io/SuperInstance/quilt-base:ubuntu`                    |

If you're starting a new Quilt agent, **use `alpine`**. Switch to
`ubuntu` only when you have a glibc dependency. Switch to `distroless`
when you ship a static binary and want to remove all shell access.
Switch to `scratch` when size matters more than debuggability.

---

## 📜 SBOMs & Attestations

Every release publishes:

1. **SPDX 2.3 SBOM** — `sbom-<variant>-<arch>.spdx.json` as a
   workflow artifact and as a cosign `spdx` attestation.
2. **CycloneDX 1.5 SBOM** — same, with `cyclonedx` attestation.
3. **Build provenance** — in-toto SLSA `https://slsa.dev/provenance/v1`
   attestation attached via `actions/attest-build-provenance`.
4. **VEX** (when applicable) — Vulnerability Exploitability eXchange
   documents for known-but-acceptable CVEs.

To verify an image:

```bash
# Pull the SBOM from the attestation.
cosign verify-attestation \
  --type spdx \
  --certificate-identity-regexp 'https://github.com/SuperInstance' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/SuperInstance/quilt-base:alpine-latest

# Verify the build provenance.
cosign verify-attestation \
  --type slsaprovenance \
  --certificate-identity-regexp 'https://github.com/SuperInstance' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/SuperInstance/quilt-base:alpine-latest
```

---

## 🔨 Building Locally

### Prerequisites

- Docker 24.0+ with BuildKit enabled
- `bash` 4+ and the usual coreutils
- (optional) `cosign`, `syft`, `trivy`, `grype` for the full pipeline

### Build a single variant

```bash
docker buildx build \
  --file docker/Dockerfile.alpine \
  --tag quilt-base:alpine-local \
  --load \
  .
```

### Build every variant and push to GHCR

```bash
export GITHUB_TOKEN=<your PAT with packages:write>
./scripts/build-all.sh
```

By default this:
- Builds all 4 variants on `linux/amd64,linux/arm64`.
- Tags each with `<variant>-<version>`, `<variant>-<date>`, and
  `<variant>-<git-sha>`. The `alpine` variant also gets `latest`.
- Scans each with Trivy (blocking) and Grype (best-effort).
- Generates SBOMs and cosign attestations.
- Pushes to `ghcr.io/SuperInstance/quilt-base`.

Pass `--no-push` to skip the registry push, `--no-scan` to skip
vulnerability scanning, or `--variant ubuntu` to build a single one.

### Build only the scratch variant with your own binary

```bash
# 1. Edit examples/rust-agent.dockerfile to point at your crate.
# 2. Build.
docker buildx build \
  --file examples/rust-agent.dockerfile \
  --tag my-agent:dev \
  --load \
  .
```

---

## 🏷️ Versioning & Tags

| Tag format                    | Mutability | Use for                              |
| ----------------------------- | ---------- | ------------------------------------ |
| `<variant>-latest`            | mutable    | Quick start, dev work                |
| `<variant>-<semver>`          | mutable    | Production (pinned to a major.minor) |
| `<variant>-<YYYYMMDD>`        | mutable    | Reproducible builds by date          |
| `<variant>-<git-sha>`         | immutable  | Exact-build pinning, audit trails    |
| `@sha256:<digest>`            | immutable  | Cryptographic pinning                |

`latest` is the `alpine` variant only. The other three variants never
receive a bare `latest` tag — they are specialized, and calling them
"the default" would mislead consumers.

We follow **semver** for the `quilt-base` *project* (this repo) but
the *images* are versioned independently per variant. A new Alpine
release is `alpine-0.2.0`; a new Ubuntu release is `ubuntu-0.2.0`.

---

## 🤝 Contributing

We welcome PRs. Before opening one, please:

1. Read `SECURITY.md` — security disclosures are NOT public issues.
2. Read `.github/CODEOWNERS` — `@CaseyDiGennaro` must approve every
   change; this is enforced at the branch-protection level.
3. Run the local pipeline: `scripts/build-all.sh --no-push`. Every
   variant must build and pass Trivy.
4. Update the SBOM target size in the affected `Dockerfile.<variant>`
   if your change materially shifts the image size.
5. If your change affects the tag scheme, update `README.md`'s
   Versioning table.

Dependabot will open PRs automatically for upstream base image bumps
and GitHub Actions version bumps. Merging those is the most common
contribution.

---

## 📄 License

```
Copyright 2025 Casey DiGennaro and the Quilt Contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

See [`LICENSE`](./LICENSE) for the full text.

---

## 🔗 Cross-References

The `quilt-base` repo is consumed by (and depends on) the following
Quilt repositories. Click through to see how each one uses these
images.

| Repo                                     | Role in the Quilt stack                          |
| ---------------------------------------- | ------------------------------------------------ |
| [`quilt-agent`](../quilt-agent)          | Orchestrator agent — runs ON `alpine`.           |
| [`quilt-worker`](../quilt-worker)        | Background job runner — runs ON `alpine`.         |
| [`quilt-elf`](../quilt-elf)              | Static-binary sidecar — runs ON `scratch`.       |
| [`quilt-pincher`](../quilt-pincher)      | Health-probe sidecar — runs ON `distroless`.     |
| [`quilt-fleet`](../quilt-fleet)          | Multi-cluster controller — runs ON `ubuntu`.     |

| Repo                                       | Why it's referenced here                          |
| ------------------------------------------ | ------------------------------------------------- |
| [`quilt-core-os`](../quilt-core-os)        | Hosts the Quilt kernel; not a consumer of this.   |
| [`quilt-standards`](../quilt-standards)    | Defines the image-tagging spec this repo follows. |
| [`quilt-ai`](../quilt-ai)                  | Pulls `alpine` for inference sidecars.            |
| [`quilt-rust`](../quilt-rust)              | Pattern reference for Rust-on-quilt-base.         |

If you maintain one of the consumer repos, the most common change you
need from `quilt-base` is **a digest bump** to pick up a security
patch. The auto-rebuild workflow opens a PR against every consumer
when the digest changes — see `scripts/auto-rebuild.yml`.

---

<sub>
Last updated: 2025-01-15 · Maintainer: <a href="https://github.com/CaseyDiGennaro">@CaseyDiGennaro</a>
</sub>
