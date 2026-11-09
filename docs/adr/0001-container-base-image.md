# ADR 0001: Container base image

- Status: Accepted
- Date: 2026-11-09
- Problem: P1 (container image)

## Context

The service is Python 3.13 (`.python-version`, `requires-python = ">=3.13,<3.14"`), with dependencies locked in
`uv.lock`. The image must be fit for production, as small and safe as is reasonable, and identical in every
environment. It must run as non-root, with a read-only root filesystem and no Linux capabilities, and report its
own health.

The base image decides four things at once: which Python runs, which C library the wheels link against, how many OS
packages (and so CVEs) ship with the service, and whether the image can be pinned and rebuilt reproducibly.

## Options considered

All sizes are uncompressed, measured locally with `docker image inspect --format '{{.Size}}'` on arm64.
CVE counts are Trivy, CRITICAL+HIGH, on 2026-11-09.

| Option | Python | Size | CRITICAL / HIGH | Notes |
|---|---|---|---|---|
| `python:3.13-slim` (Debian 13) | 3.13.18 (upstream CPython) | 202 MB base | 0 / 47 OS (none fixable) after the steps below | Docker Official Image, rebuilt on every CPython and Debian security release; exact patch tag + digest pinnable. glibc, so manylinux wheels install as-is. |
| `gcr.io/distroless/python3-debian12` | 3.11.2 | 92 MB | not scanned | Wrong minor version for `requires-python >=3.13`. Rejected. |
| `gcr.io/distroless/python3-debian13` | 3.13.5 (Debian package) | 103 MB | 0 / 33 OS | Half the size and fewer packages. But the Python is Debian's, at a different path (`/usr/bin/python3`) from any upstream builder image, so the venv has to be built on a matching Debian builder rather than the official Python image. Tags are rolling (`debian13`, `nonroot`), so only a digest pins it and there is no tag that names the Python version for Dependabot. No shell or package manager, so the zlib/pip mitigations below cannot be applied in the Dockerfile. |
| `python:3.13-alpine` | 3.13.x | smaller base | not measured | musl libc: many manylinux wheels do not apply, so packages fall back to source builds (compilers in the builder, slower builds, larger and less predictable results). Rejected. |
| Chainguard `python` | latest only | small | near zero | Excellent CVE posture, but the free tier only publishes `latest`, so the image cannot be held on Python 3.13 while upstream moves on. Pinning a digest freezes it without security updates. Rejected for this project. |

> The original plan said distroless "ships Python 3.11". That is only true of `python3-debian12`; the
> `python3-debian13` variant ships 3.13.5. The decision below still holds, for the reasons in the table.

## Decision

Use `python:3.13.18-slim` (Debian 13 "trixie"), pinned by multi-arch index digest, for both the builder and the
runtime stage. Build the venv in the builder with uv (`ghcr.io/astral-sh/uv:0.12.5`, also pinned by digest) and copy
only the venv and `app/` into the runtime stage.

Two hardening steps in the runtime stage, both driven by the Trivy scan:

1. `apt-get install --only-upgrade zlib1g`: the pinned digest predates the Debian security build that fixes two
   HIGH zlib CVEs (CVE-2026-76844, CVE-2026-85091). Remove the step once a newer base digest carries the fix.
2. Delete `pip` and `ensurepip`. uv installs everything at build time; an installer has no job at run time, and
   pip's vendored `urllib3`, `msgpack` and `setuptools` accounted for all 5 HIGH Python-package findings.

## Consequences

- Image: **228 MB uncompressed (`docker image inspect` 227,754,942 bytes), 49.2 MB compressed content.** The base
  is 202 MB of that; the app's venv is 19.5 MB and the code 29 kB. Deleting pip in a later layer hides it but does not
  shrink the base layer, so the size gain from that step is nil; the point is that the scanner and an attacker no
  longer find an installer.
- Trivy (CRITICAL,HIGH): **0 CRITICAL, 47 HIGH, all in Debian OS packages with no fix available** (46 `affected`,
  1 `fix_deferred`; 11 unique CVEs in util-linux, ncurses, sqlite, systemd libs, libacl, perl-base). 0 Python-package
  findings. With `--ignore-unfixed` the scan is clean, so CI can gate on fixable CRITICAL/HIGH without a permanent
  allow-list.
- The remaining OS CVEs are in Debian `Essential` packages that cannot be removed cleanly. The service does not invoke
  them, runs as UID 10001 with `--cap-drop ALL`, `no-new-privileges` and a read-only root filesystem, which removes
  the usual exploitation paths (setuid binaries, writing to the filesystem).
- A shell is still present (`/bin/sh`). That helps debugging (`docker exec`) at the cost of a slightly larger attack
  surface than distroless. Revisit distroless debian13 if the CVE count becomes the binding constraint.
- Pinned digests do not update themselves. Dependabot (P2) must track `python` and `ghcr.io/astral-sh/uv` in the
  `docker` ecosystem so security rebuilds arrive as PRs.
