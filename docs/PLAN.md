# Delivery plan

This document is the design intent for each problem. Each PR links back here and records anything that changed.

## Target repository layout

```
tdb-devops-handson/
├── app/                              # FastAPI service                           (setup)
│   ├── config.py                     #   env-only settings (pydantic-settings)
│   ├── models.py                     #   API contract (pydantic models)
│   ├── repository.py                 #   data access (sample data for now)
│   ├── main.py                       #   routes + server entry point
│   └── metrics.py                    #   Prometheus instrumentation             (P5)
├── tests/                            # pytest
├── Dockerfile, .dockerignore         # production image                          (P1)
├── compose.yaml                      # local stack: app + postgres (+ prometheus) (P1, P5)
├── .github/
│   ├── pull_request_template.md      #                                           (setup)
│   ├── dependabot.yml                # actions, uv, docker base image            (P2)
│   └── workflows/
│       ├── ci.yaml                   # lint, types, tests, image build, scans, GHCR publish (P2)
│       ├── helm.yaml                 # helm lint, template, kubeconform          (P3)
│       ├── terraform.yaml            # fmt, validate, tflint, checkov            (P4)
│       └── monitoring.yaml           # promtool check rules + rule unit tests    (P5)
├── charts/tdb-bookings/              # Helm chart                                (P3)
│   ├── values.yaml, values.schema.json, values-dev.yaml, values-prod.yaml
│   └── templates/ (deployment, service, configmap, hpa, pdb, serviceaccount, networkpolicy)
├── infra/terraform/                  # AWS                                       (P4)
│   ├── bootstrap/                    #   S3 state bucket (one-time, per account)
│   ├── modules/network/              #   VPC, subnets, NAT, flow logs
│   ├── modules/postgres/             #   RDS PostgreSQL, SG, subnet group, params
│   └── envs/{dev,prod}/              #   root modules + S3 backend config
├── monitoring/prometheus/            # SLO recording + alerting rules, rule tests (P5)
└── docs/
    ├── PLAN.md                       # this file
    ├── architecture/                 # AWS, network, data and CI/CD diagrams (as code)
    ├── adr/                          # one short decision record per significant choice
    └── runbooks/                     # one runbook per alert                     (P5)
```

## Setup (initial commit on `main`)

- Python 3.13, FastAPI, pydantic-settings, uvicorn. Dependencies locked with `uv`.
- `GET /health` → `200 {"status":"ok"}`, does not touch the database.
- `GET /bookings` → typed sample list `{"items":[…],"count":N}`.
- `PORT`, `HOST`, `APP_ENV`, `LOG_LEVEL`, `DATABASE_URL` from env. `DATABASE_URL` is a `SecretStr` so it never
  appears in logs or `repr`.
- Tests: health, bookings, settings-from-env (including "the DB URL is not leaked").
- ruff (lint + format, including bandit `S` rules), mypy `--strict`, pytest with warnings as errors.

## P1: Container image (`feature/p1-container-image`)

| Requirement | Design |
|---|---|
| Production-fit image | Multi-stage: `builder` installs the locked deps with `uv sync --frozen --no-dev` into `/app/.venv`; `runtime` copies only the venv and `app/`. No compilers, no uv, no tests in the final image. |
| Small and safe | `python:3.13-slim` pinned **by digest**. Non-root UID/GID `10001`, no shell login, `PYTHONDONTWRITEBYTECODE`, works with a read-only root filesystem. Image size measured and stated in the PR. |
| Same image everywhere | No env-specific build args. Everything from env vars at runtime. |
| Reports health | `HEALTHCHECK` using the image's own Python (`urllib`), so no curl is added. Kubernetes uses its own probes (P3). |
| Signals / shutdown | `exec`-form `CMD`, so uvicorn is PID 1 and gets SIGTERM for graceful shutdown. |

Base image options compared in the PR and in `docs/adr/0001-container-base-image.md`: `python:3.13-slim` (chosen:
exact Python version in the tag so Dependabot can track it, glibc wheels work, apt available for security fixes) vs
`distroless/python3-debian13` (smaller and also Python 3.13, but a Debian-packaged Python at a different path, tags do
not name the Python version, and no apt to patch OS CVEs between base releases) vs `alpine` (musl: wheels rebuild from
source) vs Chainguard (near-zero CVEs, but only the `latest` tag is free, so it cannot be pinned to a Python minor).

Local proof: `docker build`, `docker run -e PORT=…`, `curl /health`, `docker inspect` (User, Health status, Size),
container started with `--read-only --cap-drop ALL`.

## P2: CI pipeline (`feature/p2-ci-pipeline`)

`ci.yaml`, triggered on `pull_request` and `push` to `main`:

1. **quality**: `uv sync --frozen`, ruff, mypy, pytest with coverage. uv cache enabled.
2. **security (code)**: `pip-audit` on the lock (dependency CVEs), gitleaks (committed secrets), hadolint (Dockerfile).
3. **image**: buildx build with the GitHub Actions layer cache (`cache-from/to: type=gha`), load locally, then
   **Trivy** image scan:
   - `CRITICAL` → exit code 1, **including unfixed** ones. The publish step comes after the scan in the same job, so
     a critical stops the publish.
   - `HIGH`/`MEDIUM` → SARIF uploaded to GitHub code scanning (visible, non-blocking).
4. **publish** (only on `push` to `main`, after scan passes): push to `ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson`
   - tags: `sha-<full 40-char commit sha>` (immutable, traces to the commit) and `main` (moving);
   - OCI labels `org.opencontainers.image.revision`, `.source`, `.created`;
   - build provenance attestation + SBOM, so `gh attestation verify` proves which workflow and commit built it.

Hardening: least-privilege `permissions:` per job, actions pinned by commit SHA, `concurrency` cancels superseded PR
runs. Dependabot keeps actions, Python deps and the base image digest current.

## P3: Helm chart (`feature/p3-helm-chart`)

| Requirement | Design |
|---|---|
| Deploys the service | Deployment, Service, ConfigMap, ServiceAccount (`automountServiceAccountToken: false`), NetworkPolicy. |
| dev / prod | `values-dev.yaml` (1 replica, no HPA, small resources); `values-prod.yaml` (min 3 replicas, HPA 3→10). |
| Zero-downtime release | RollingUpdate `maxUnavailable: 0, maxSurge: 25%`; readiness probe on `/health`; `preStop` sleep + `terminationGracePeriodSeconds` so endpoints drain before SIGTERM; config checksum annotation rolls pods on config change. |
| Scales with load | `autoscaling/v2` HPA on CPU (and memory) with requests set. |
| Survives node drain | PodDisruptionBudget `maxUnavailable: 1` in prod (one pod at a time at any replica count); `topologySpreadConstraints` across zones and nodes, so one drained node or zone never takes all replicas. |
| Config vs secrets | Non-secret config in a ConfigMap. `DATABASE_URL` read via `secretKeyRef` from an **existing** Secret (`secret.existingSecret`), created out of band (External Secrets Operator syncing AWS Secrets Manager in real envs; `kubectl create secret` locally). The chart never renders a Secret value. |
| Pod security | `runAsNonRoot`, `readOnlyRootFilesystem`, drop ALL capabilities, `seccompProfile: RuntimeDefault`, no privilege escalation. |
| Input validation | `values.schema.json`: bad values fail at `helm lint` / `install`, not at runtime. |

CI (`helm.yaml`, every PR): `helm lint --strict` and `helm template` for dev and prod, piped to
`kubeconform -strict -summary` against a pinned Kubernetes version.
Local proof (optional item, will do): kind cluster, `helm upgrade --install` with prod values, rollout with zero failed
requests during an upgrade, `kubectl drain` with the PDB holding.

## P4: Terraform for AWS (`feature/p4-terraform-aws`)

| Requirement | Design |
|---|---|
| Network + PostgreSQL, dev and prod | `modules/network` + `modules/postgres`, composed by `envs/dev` and `envs/prod` (separate state per env). |
| Survive loss of one AZ (prod) | 3 AZs; public, private-app and private-db subnets in each; **one NAT gateway per AZ**; RDS `multi_az = true` (synchronous standby, automatic failover). Dev: 2 AZs, single NAT, single-AZ DB to save cost (stated trade-off). |
| DB not reachable from internet | DB subnets have no route to an internet gateway; `publicly_accessible = false`; security group allows 5432 only from the app security group; `rds.force_ssl = 1`. |
| Secrets | `manage_master_user_password = true`: AWS generates the password and keeps it in Secrets Manager. No password in code, tfvars or state. Storage encrypted with KMS. |
| Team works safely in parallel | S3 backend per env, versioned + encrypted bucket, **native S3 state locking** (`use_lockfile = true`, Terraform ≥ 1.10, no DynamoDB table needed). Bucket created once by `bootstrap/`. Provider and Terraform versions pinned; `.terraform.lock.hcl` committed. |
| Production safety | `deletion_protection`, final snapshot, backups (7 d dev / 30 d prod), Performance Insights, VPC flow logs. |

Never `terraform apply`. CI (`terraform.yaml`, every PR): `terraform fmt -check -recursive`,
`init -backend=false` + `validate` for each env, `tflint` (AWS ruleset), `checkov` (SARIF to code scanning). Any skipped
check carries an inline reason.

## P5: Alerts and runbook (`feature/p5-alerts-runbook`)

SLO: **99.9% of booking requests succeed in under 1 s, over 30 days.** A request is *good* when it is not a 5xx **and**
finishes in ≤ 1 s. Error budget = 0.1%.

- **Metrics** (`prometheus_client`, `/metrics`): histogram `http_request_duration_seconds{method,route,status_class}`
  with a bucket exactly at `1.0`. Labelled by route *template* (not raw path) to keep cardinality bounded. One metric
  gives both parts of the SLI:
  `good = rate(bucket{route="/bookings",le="1",status_class!="5xx"})`, `total = rate(count{route="/bookings"})`.
- **Recording rules**: error ratio over 5m, 30m, 1h, 2h, 6h, 1d, 3d, 30d.
- **Alerts** (multi-window, multi-burn-rate, Google SRE Workbook):

  | Alert | Burn rate | Windows | Budget used before it fires | Severity |
  |---|---|---|---|---|
  | `BookingsErrorBudgetFastBurn` | 14.4× | 1h and 5m | 2% in 1 h | page |
  | `BookingsErrorBudgetFastBurn` | 6× | 6h and 30m | 5% in 6 h | page |
  | `BookingsErrorBudgetSlowBurn` | 3× | 1d and 2h | 10% in 1 d | ticket |
  | `BookingsErrorBudgetSlowBurn` | 1× | 3d and 6h | 10% in 3 d | ticket |
  | `BookingsErrorBudgetLow` | n/a | 30d | > 75% of the month's budget gone | ticket |
  | `BookingsMetricsAbsent` | n/a | 10m | no data = no SLO alerts, so this is a page | page |

- Every alert has `runbook_url` → `docs/runbooks/<alert>.md`. Full runbook written for `BookingsErrorBudgetFastBurn`
  (what it means, how to check, what to do, escalation); short stubs for the others.
- CI (`monitoring.yaml`): `promtool check rules` and `promtool test rules` (unit tests that feed synthetic series and
  assert each alert fires / stays quiet), run from the pinned `prom/prometheus` image.
- Local proof: compose stack with app + Prometheus, load generated, rules loaded and visible in Prometheus.

## Working method (agents)

- Each problem is drafted by an implementation agent against this plan, then **reviewed by a fresh agent** that did not
  write it. Each finding is checked against the code before it becomes a PR line comment and a follow-up commit.
- Everything is verified locally before push (Docker, kind, terraform/tflint/checkov, promtool), then CI must be green.
- Proof for each PR (command output, CI run, image tag) goes in its "How to verify" section.
