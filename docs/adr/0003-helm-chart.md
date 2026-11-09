# ADR 0003: Helm chart for the bookings service

- Status: accepted
- Date: 2026-11-09
- Problem: P3

## Context

The service must run on Kubernetes in dev and prod, release without downtime, scale with load, survive node drains,
and keep configuration apart from secrets, with no secret value in git.

## Decision

One chart, `charts/tdb-bookings`, with per-environment values files (`values-dev.yaml`, `values-prod.yaml`) on top
of safe defaults, and a `values.schema.json` that rejects bad input at `helm lint` / `install` time.

- **Secrets by reference only.** The chart reads `DATABASE_URL` with `secretKeyRef` from an existing Secret
  (`secret.existingSecret`). It never renders a Secret. In AWS the Secret is synced from Secrets Manager by External
  Secrets Operator; locally it is created with `kubectl create secret`.
- **Immutable images in prod.** `values-prod.yaml` sets no image; every prod release passes `image.digest` (or a
  `sha-<commit>` tag) and the schema rejects a release without one.
- **Zero-downtime rollout:** `maxUnavailable: 0`, startup + readiness probes on the dependency-free `/health`,
  `minReadySeconds`, `preStop` sleep before SIGTERM, grace period checked to be longer than the sleep.
- **Availability:** HPA 3–10 (CPU + memory), PDB `minAvailable: 2` with `unhealthyPodEvictionPolicy: AlwaysAllow`,
  topology spread hard across nodes and soft across zones with `nodeTaintsPolicy: Honor`.
- **Cross-field rules in templates** (`fail`) where JSON Schema draft-07 cannot express them: grace period > preStop,
  HPA min ≤ max, PDB `minAvailable` < minimum replicas.
- **CI** (`helm.yaml`): `helm lint --strict`, `helm template` and `kubeconform -strict` against Kubernetes 1.33 for
  both environments, plus assertions on the rendered prod output (no Secret, secretKeyRef only, HPA floor 3, PDB 2,
  `maxUnavailable: 0`, spread) and a negative test that prod without an image fails lint.

## Alternatives considered

- **Kustomize overlays:** no input validation or packaging/rollback story comparable to a schema-checked chart plus
  `helm rollback`.
- **Chart-rendered Secret from `--set`:** puts the value into Helm's release Secret and shell history; rejected.
- **Native `preStop.sleep` action:** no binary needed, but GA only from Kubernetes 1.34; the image has `/bin/sleep`,
  so `exec` works on every supported version.
- **CPU limit:** CFS throttling raises tail latency; the request already guarantees a share and drives the HPA.
  Available as an opt-in value.
- **Zone spread `DoNotSchedule`:** stronger guarantee, but a zone short of capacity would leave pods Pending during
  scale-up; nodes are spread hard instead.

## Consequences

- Deployers must create the DB Secret before installing prod values (pods stay in `CreateContainerConfigError`
  otherwise; NOTES.txt says so).
- With the HPA owning `replicas`, a brand-new Deployment starts at 1 pod for one HPA sync (~15 s).
- The prod NetworkPolicy uses the VPC CIDR (`10.0.0.0/16`), which must stay equal to the Terraform VPC CIDR.
