# ADR 0002: CI pipeline (GitHub Actions)

- Status: accepted
- Date: 2026-11-09
- Problem: P2 (`.github/workflows/ci.yaml`, `.github/dependabot.yml`)

## Context

Every pull request must be built, linted, tested and have its image scanned. Every merge to `main` must publish the
image to GHCR, a critical vulnerability must stop publishing, anyone must be able to tell which commit an image came
from, and repeat runs should be fast.

## Decision

One workflow, `ci.yaml`, four jobs:

| Job (check name) | Runs on | What it does |
|---|---|---|
| `lint-test` (**Lint, type-check, test**) | PR, push to main | `uv sync --locked` (fails if `uv.lock` is stale), ruff, ruff format, mypy, pytest with coverage (fails under 80%) |
| `security` (**Secret, dependency and Dockerfile scans**) | PR, push to main | gitleaks over the full git history, hadolint on `Dockerfile`, pip-audit (itself installed from a hash-locked file) on the locked runtime dependencies |
| `image` (**Image build and scan**) | PR, push to main; needs both jobs above | buildx build (GHA layer cache) → Trivy gate → Trivy SARIF (non-blocking). Token: `contents: read`, `security-events: write` only |
| `publish` (**Publish to GHCR**) | push to main only, `release` environment; needs `image` | push by digest (untagged) → Trivy gate on **that exact digest** with a fresh DB → tag `sha-<commit>` → move `main` if still the head → signed attestation |

### Publishing is a separate job that re-scans what it pushes

PR runs never hold a token that can write packages or sign: only `publish` has `packages: write`, `id-token: write`
and `attestations: write`, and it only runs for pushes to `main` through the `release` environment (deployment branch
policy: `main`). PR code (tests, the Dockerfile's `RUN` steps, scanners) therefore never runs next to publishing
credentials.

The publish build reuses the layer cache, but it is still a build, so we do not assume it equals the image `image`
scanned. It is pushed **by digest only** (no tag), then Trivy scans that pushed digest from the registry with a freshly
downloaded DB. Only if that passes does the digest get the `sha-<commit>` tag. A CRITICAL therefore leaves at most an
untagged manifest in GHCR, never a tagged image.

The runtime stage is built with `no-cache-filters: runtime`, because the Dockerfile applies an unpinned Debian
security upgrade there; a cached copy would freeze that fix forever.

Remaining risk, stated plainly: GitHub grants token permissions from the workflow file of the ref being run, so a
collaborator with write access could push a branch whose own workflow asks for `packages: write` and pushes an image
before review. Branch rules and CODEOWNERS only gate the merge, not that run. Collaborators are therefore trusted, and
consumers should verify attestations with `--signer-workflow` and `--source-ref refs/heads/main` (below), which a
branch run cannot satisfy.

### What blocks what

- Any `CRITICAL` vulnerability, **fixed or not**, fails the job (`--ignore-unfixed` is deliberately not set). An
  exception must be a reviewed `.trivyignore` entry.
- `HIGH` and `MEDIUM` are uploaded as SARIF to code scanning (Security tab, PR annotations) and do not block. The
  report step also runs when the gate failed, so the blocking findings are visible there too.
- `image` needs `lint-test` and `security`, and `publish` needs `image`: a commit with a leaked secret or a vulnerable
  locked dependency is never published.
- The SARIF report and upload steps are `continue-on-error`: a code-scanning outage cannot block publishing.

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
- The publish gate always downloads a fresh Trivy DB; the cached DB only speeds up the `image` job.
- `actionlint` and `zizmor` (auditor persona) pass on the workflow.

### Speed on repeat runs

uv download cache (keyed on `uv.lock`), Docker layer cache in the GitHub Actions cache (`type=gha,mode=max`, the
Dockerfile installs dependencies before copying code), Trivy DB cached per day for the `image` job, lint/test and security
jobs in parallel, superseded PR runs cancelled.

## Tags and tracing an image to its commit

| Tag | Meaning |
|---|---|
| `ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson:sha-<40-char commit SHA>` | One per commit on `main`, never overwritten: a re-run finds the existing tag and reuses its digest instead of building a new one. Deploy this, or better the digest. |
| `ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson:main` | Moving pointer to the latest published commit. |

Every merged commit gets its own `sha-` image. Publish runs are serialised (`concurrency: publish-ghcr`, never
cancelled), and `:main` is only moved when the commit being published is still the head of `main`, so a run that
finishes late can never roll `:main` back to an older commit.

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

# 4. Signed GitHub attestation: proves ci.yaml on main in this repo built this digest from this commit
gh attestation verify "oci://$IMAGE:main" --repo ashish-sharma-edstem-dev/tdb-devops-handson \
  --signer-workflow ashish-sharma-edstem-dev/tdb-devops-handson/.github/workflows/ci.yaml \
  --source-ref refs/heads/main
```

The run's job summary prints the image digest, tags, commit and the verify commands.

## Not covered

- Tool versions inside `ci.yaml` (uv, gitleaks, hadolint, Trivy) and `.github/tools/pip-audit.txt` are not updated by
  Dependabot; bump them by hand (release checksums file / `uv pip compile --generate-hashes`).
- `harden-runner` is in `audit` mode (logs egress, blocks nothing). Switching to `block` needs an allow-list built
  from a few runs' egress reports.
- A CRITICAL found by the publish gate leaves an untagged manifest in GHCR; delete it from the package page.
- `linux/amd64` only. Adding `linux/arm64` needs QEMU or an arm runner and roughly doubles build time.
- GHCR package visibility: the first push creates the package; if it is private, make it public once in the package
  settings (repository setting, not automatable from the workflow without a broader token).
