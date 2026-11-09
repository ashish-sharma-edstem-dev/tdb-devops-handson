# tdb-devops-handson

A minimal bookings web service, and everything needed to run it in production: container image, CI/CD,
Helm chart, AWS Terraform, and SLO-based alerting with a runbook.

The service is deliberately small. The delivery around it is the point. Design and decisions for every part are in
[`docs/PLAN.md`](docs/PLAN.md). Rules for contributors and AI agents are in [`AGENTS.md`](AGENTS.md).

![AWS architecture](docs/architecture/aws-architecture.png)

Architecture, network flow, data flow and CI/CD diagrams: [`docs/architecture/`](docs/architecture/README.md).

## Service

Python 3.13, FastAPI.

| Endpoint | Response |
|---|---|
| `GET /health` | `200 {"status":"ok"}`. Liveness only; does not touch the database. |
| `GET /bookings` | `200 {"items":[…],"count":3}`. Sample bookings. |
| `GET /docs` | OpenAPI UI generated from the code. |

### Configuration

All configuration comes from environment variables. The same build runs in every environment.

| Variable | Default | Notes |
|---|---|---|
| `PORT` | `8080` | HTTP port. |
| `HOST` | `0.0.0.0` | Bind address. |
| `APP_ENV` | `local` | Environment name. |
| `LOG_LEVEL` | `info` | Uvicorn log level. |
| `DATABASE_URL` | unset | PostgreSQL URL. Treated as a secret: never logged. Comes from a Kubernetes Secret / AWS Secrets Manager outside local runs. |

### Run locally

Requires [uv](https://docs.astral.sh/uv/).

```bash
uv sync --locked
PORT=8080 uv run python -m app.main
curl -s localhost:8080/health      # {"status":"ok"}
curl -s localhost:8080/bookings
```

### Checks

```bash
make check     # ruff lint + format check, mypy --strict, pytest
```

## Delivery

| Problem | Branch | What it adds |
|---|---|---|
| P1 Container image | `feature/p1-container-image` | `Dockerfile` |
| P2 CI pipeline | `feature/p2-ci-pipeline` | `.github/workflows/ci.yaml` |
| P3 Helm chart | `feature/p3-helm-chart` | `charts/tdb-bookings/` |
| P4 Terraform for AWS | `feature/p4-terraform-aws` | `infra/terraform/` |
| P5 Alerts and runbook | `feature/p5-alerts-runbook` | `monitoring/`, `docs/runbooks/` |

Each problem is one branch, one PR (using [the template](.github/pull_request_template.md)), one review and one
merge into `main`, in order. Sections below are filled in as each PR lands.

## P1: Container image

```bash
make docker-build                    # docker build -t tdb-bookings:local .
make docker-run PORT=9000            # read-only root fs, no capabilities, no-new-privileges
curl -s localhost:9000/health        # {"status":"ok"}
docker inspect --format '{{.Config.User}} {{.State.Health.Status}}' <container>   # 10001:10001 healthy
```

- Multi-stage build on `python:3.13-slim`, pinned by digest. Final image: **230 MB uncompressed / ~49 MB compressed**
  (202 MB is the base; app dependencies 19.5 MB).
- Runs as UID/GID `10001`. pip, uv, compilers and setuid bits are not in the final image.
- `HEALTHCHECK` uses the image's own Python, so no curl is added.
- The same image runs everywhere: `PORT`, `APP_ENV`, `DATABASE_URL`, … come from the environment at run time.
- Why this base image: [`docs/adr/0001-container-base-image.md`](docs/adr/0001-container-base-image.md).

## P2: CI pipeline

[`.github/workflows/ci.yaml`](.github/workflows/ci.yaml) runs on every PR and on every push to `main`:

| Check | What it does |
|---|---|
| `Lint, type-check, test` | `uv sync --locked` (a stale lock fails), ruff, ruff format, mypy `--strict`, pytest with coverage ≥ 80% |
| `Secret, dependency and Dockerfile scans` | gitleaks over full history, pip-audit on the locked runtime deps, hadolint |
| `Image build and scan` | buildx build with the GitHub Actions layer cache, then a Trivy gate: **any CRITICAL (fixed or not) fails the job**. Read-only token |
| `Publish to GHCR` (main only) | Pushes by digest, **re-scans that exact digest** with a fresh Trivy DB, and only then tags it `sha-<commit>`; moves `main` only if the commit is still the head of `main`; SBOM, provenance and a signed attestation |

Published image: `ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson`, tags `sha-<full commit sha>` (one per commit,
never overwritten) and `main`. To trace an image back to its commit:

```bash
docker buildx imagetools inspect ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson:main \
  --format '{{ index .Image.Config.Labels "org.opencontainers.image.revision" }}'
gh attestation verify oci://ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson:sha-<commit> \
  --repo ashish-sharma-edstem-dev/tdb-devops-handson \
  --signer-workflow ashish-sharma-edstem-dev/tdb-devops-handson/.github/workflows/ci.yaml --source-ref refs/heads/main
```

Hardening: only the main-only `publish` job (in the `release` environment) can write packages or sign; every action
pinned to a commit SHA, least-privilege `permissions:` per job, no `pull_request_target`, pip-audit from a hash lock,
scanners installed as checksum-verified binaries (the `trivy-action` tags were hijacked in March 2026), Dependabot
for actions, uv and base images. Details: [`docs/adr/0002-ci-pipeline.md`](docs/adr/0002-ci-pipeline.md).

## P3: Helm chart

[`charts/tdb-bookings/`](charts/tdb-bookings/README.md): Deployment, Service, ConfigMap, ServiceAccount (no API token),
HPA, PodDisruptionBudget, NetworkPolicy, optional Ingress, a `helm test`, and a values schema that rejects bad input.

| | dev (`values-dev.yaml`) | prod (`values-prod.yaml`) |
|---|---|---|
| Replicas | 1 | HPA 3 → 10 (CPU 70%, memory 80%) |
| Disruptions | none | PDB `maxUnavailable: 1`, spread across zones and nodes |
| Image | `main` tag | must be pinned: `image.digest` or `image.tag=sha-<commit>` (schema enforces) |

- **No downtime on release:** `maxUnavailable: 0`, readiness gate on `/health`, `preStop` sleep so the endpoint is
  removed before SIGTERM, `--atomic` rollback.
- **Config vs secrets:** settings in a ConfigMap; `DATABASE_URL` only via `secretKeyRef` to an existing Secret (External
  Secrets Operator from AWS Secrets Manager in real environments). The chart never renders a Secret.
- **Pod security:** non-root 10001, read-only root filesystem, all capabilities dropped, `RuntimeDefault` seccomp; runs
  in a namespace enforcing the `restricted` Pod Security Standard.
- **CI:** `.github/workflows/helm.yaml` runs `helm lint --strict`, `helm template` and `kubeconform -strict` for dev and
  prod on every PR, plus checks that no Secret is rendered and that the prod guarantees hold.

**Tested on a local kind cluster** (3 workers in 3 zones, prod values, steps in the chart README):

| Scenario, under continuous in-cluster load (every 50 ms) | Result |
|---|---|
| Install, `helm test` | 3 pods, one per zone; test pod `Succeeded` |
| Rolling upgrade (config change → new ReplicaSet) | `ok=5343 errors=0` |
| Drain two of three workers at once | PDB allowed one eviction at a time ("would violate the pod's disruption budget"), pods moved one at a time: `ok=1616 errors=0` |

## P4: Terraform for AWS

[`infra/terraform/`](infra/terraform/README.md): VPC and PostgreSQL for dev and prod in `ap-south-1`. Never applied from
this repo; CI runs `fmt`, `validate`, plan-time `terraform test` with a mocked provider, `tflint` and `checkov`.

| | dev | prod |
|---|---|---|
| AZs | 2 | 3 (survives the loss of one) |
| NAT | 1 shared | 1 per AZ; each app subnet routes to the NAT in its own AZ |
| PostgreSQL | single-AZ, `db.t4g.micro` | Multi-AZ (synchronous standby, automatic failover), deletion protection, 30-day backups |

- **Not reachable from the internet:** DB subnets have no internet route, `publicly_accessible = false`, and `sg-db`
  allows 5432 only from `sg-app`. TLS is enforced on top (`rds.force_ssl = 1`).
- **No secrets:** RDS generates the master password into Secrets Manager (`manage_master_user_password`), KMS-encrypted.
- **Team-safe state:** S3 backend per env (versioned, SSE-KMS, TLS-only bucket policy) with **native S3 locking**
  (`use_lockfile = true`): a second `plan`/`apply` on the same env fails with "Error acquiring the state lock" instead
  of writing. Details: [How Terraform state is stored and shared](infra/terraform/README.md#how-terraform-state-is-stored-and-shared).
