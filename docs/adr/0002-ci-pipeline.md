# ADR 0002: CI pipeline (GitHub Actions)

- Status: accepted
- Date: 2026-11-09
- Problem: P2 (`.github/workflows/ci.yaml`, `.github/dependabot.yml`)

## Context

Every pull request must be built, linted, tested and have its image scanned. Every merge to `main` must publish the
image to GHCR, a critical vulnerability must stop publishing, anyone must be able to tell which commit an image came
from, and repeat runs should be fast.

## Decision

One workflow, `ci.yaml`, three jobs:

| Job (check name) | Runs on | What it does |
|---|---|---|
| `lint-test` (**Lint, type-check, test**) | PR, push to main | `uv lock --check`, `uv sync --frozen`, ruff, ruff format, mypy, pytest with coverage (fails under 80%) |
| `security` (**Secret, dependency and Dockerfile scans**) | PR, push to main | gitleaks over the full git history, hadolint on `Dockerfile`, pip-audit on the locked runtime dependencies |
| `image` (**Image build, scan, publish**) | PR, push to main; needs both jobs above | buildx build (GHA layer cache) → Trivy gate → Trivy SARIF → *(push to main only)* push, SBOM, provenance, attestation |

### Single workflow, gate before push in the same job

The image that is scanned and the image that is pushed are produced by the same buildx builder in the same job, from
the same context, build args and labels. The push build is a full cache hit, so the pushed layers are the layers Trivy
scanned; only the attestation manifests are new. Publishing is the last step of the job, so a failing Trivy gate ends
the job before any registry login happens. A separate publish job would need the image passed between jobs (a tarball
loses the attestations) or a rebuild on a different runner, which breaks the "what was scanned is what ships" link.

Trade-off: the `image` job declares `packages: write`, `id-token: write` and `attestations: write` on PR runs too, even
though the publish steps only run on `push` to `main` (job permissions cannot depend on the event). Mitigations: PRs
from forks always receive a read-only token; only collaborators can open same-repo PRs; the token is never exposed to a
`run:` step or to the Docker build (checkout uses `persist-credentials: false`, the build gets no secrets), only to
SHA-pinned actions as their default `github-token`; CODEOWNERS covers `.github/`.

### What blocks what

- Any `CRITICAL` vulnerability, **fixed or not**, fails the job (`--ignore-unfixed` is deliberately not set). An
  exception must be a reviewed `.trivyignore` entry.
- `HIGH` and `MEDIUM` are uploaded as SARIF to code scanning (Security tab, PR annotations) and do not block. The
  report step also runs when the gate failed, so the blocking findings are visible there too.
- `image` needs `lint-test` and `security`: a commit with a leaked secret or a vulnerable locked dependency is never
  built for publishing.

### Supply chain of the pipeline itself

- Every action is pinned to a full 40-character commit SHA with the tag in a comment (Dependabot updates both).
- Scanners (gitleaks, hadolint, Trivy) are downloaded as pinned release binaries and checked against a hard-coded
  SHA-256. Trivy is deliberately **not** run through `aquasecurity/trivy-action`: 76 of its 77 tags were force-pushed to
  credential-stealing commits in March 2026 ([GHSA-69fq-xp46-6x23](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23)),
  and a security gate should not depend on a composite action that itself downloads
  Trivy. One verified binary is the smallest trust surface.
- Pins are the newest release that was at least 14 days old when chosen; Dependabot uses a 7-day cooldown.
- `permissions: {}` at the top, least privilege per job, no `pull_request_target`, `step-security/harden-runner`
  (egress audit) first in every job, `persist-credentials: false` on checkout.
- On publishing runs the Trivy DB is always downloaded fresh, never restored from the Actions cache.
- `actionlint` and `zizmor` (auditor persona) pass on the workflow.

### Speed on repeat runs

uv download cache (keyed on `uv.lock`), Docker layer cache in the GitHub Actions cache (`type=gha,mode=max`, the
Dockerfile installs dependencies before copying code), Trivy DB cached per day on PR runs, lint/test and security
jobs in parallel, superseded PR runs cancelled.

## Tags and tracing an image to its commit

| Tag | Meaning |
|---|---|
| `ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson:sha-<40-char commit SHA>` | Immutable, one per commit on `main`. Deploy this (or the digest). |
| `ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson:main` | Moving pointer to the latest published commit. |

Concurrency on `main` is one group per commit, so every merged commit gets its own image; if two merges finish out
of order, `:main` can briefly point at the older one. The `sha-` tags are never affected.

Four independent ways to get from an image to its commit:

```sh
IMAGE=ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson

# 1. The tag itself
docker buildx imagetools inspect "$IMAGE:main"          # lists the digest; find the matching sha-<commit> tag in GHCR

# 2. OCI label set by CI
docker pull "$IMAGE:main"
docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$IMAGE:main"

# 3. SLSA provenance stored with the image by buildx (mode=max: commit, workflow, build args)
docker buildx imagetools inspect "$IMAGE:main" --format '{{ json .Provenance }}'

# 4. Signed GitHub attestation: proves this repo's workflow built this digest from this commit
gh attestation verify "oci://$IMAGE:main" --owner ashish-sharma-edstem-dev
```

The run's job summary prints the image digest, tags, commit and the verify commands.

## Not covered

- Tool versions inside `ci.yaml` (uv, gitleaks, hadolint, Trivy, pip-audit) are not updated by Dependabot; bump them by
  hand with the hash from the release checksums file.
- `linux/amd64` only. Adding `linux/arm64` needs QEMU or an arm runner and roughly doubles build time.
- GHCR package visibility: the first push creates the package; if it is private, make it public once in the package
  settings (repository setting, not automatable from the workflow without a broader token).
