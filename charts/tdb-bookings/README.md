# tdb-bookings Helm chart

Deploys the bookings API to Kubernetes: Deployment, Service, ConfigMap, ServiceAccount and, per environment, an
HPA, a PodDisruptionBudget, a NetworkPolicy and an optional Ingress. Kubernetes ≥ 1.27; validated against 1.33.

| File | Purpose |
|---|---|
| `values.yaml` | Documented, safe defaults (1 replica, nothing optional enabled, locked-down pod). |
| `values.schema.json` | JSON Schema for every value. Wrong types, typos and unsafe settings fail `helm lint` / `helm install`. |
| `values-dev.yaml` | Dev: 1 small replica, no HPA / PDB / NetworkPolicy, follows the `main` image tag. |
| `values-prod.yaml` | Prod: HPA 3–10, PDB `maxUnavailable: 1`, spread across zones and nodes, NetworkPolicy, DB Secret. |
| `ci/kind-config.yaml` | Local 3-zone kind cluster for the steps at the end of this file. |

## Install

```bash
# Dev: follows the moving `main` tag (pullPolicy Always), runs on sample data without a database.
helm upgrade --install tdb-bookings charts/tdb-bookings -n tdb-dev --create-namespace \
  -f charts/tdb-bookings/values-dev.yaml

# Prod: the image must be named explicitly and immutably; the schema rejects an install without it.
# image.digest is preferred (or --set image.tag=sha-<40-char commit sha>). --atomic rolls back automatically
# if the new pods never become Ready.
helm upgrade --install tdb-bookings charts/tdb-bookings -n tdb-prod \
  -f charts/tdb-bookings/values-prod.yaml \
  --set image.digest=sha256:<digest> \
  --atomic --wait --timeout 10m
helm -n tdb-prod test tdb-bookings              # GET /health through the Service
```

`helm template` / `helm lint` the same way to see or check the output without a cluster:

```bash
helm lint --strict charts/tdb-bookings -f charts/tdb-bookings/values-prod.yaml --set image.tag=sha-$(git rev-parse HEAD)
helm template tdb-bookings charts/tdb-bookings -n tdb-prod -f charts/tdb-bookings/values-prod.yaml \
  --set image.tag=sha-$(git rev-parse HEAD) --kube-version 1.33.0 \
  | kubeconform -strict -summary -kubernetes-version 1.33.0
```

CI runs exactly this for both environments on every PR (`.github/workflows/helm.yaml`, check
**Helm lint and validate (dev, prod)**), plus assertions that no Secret is rendered and that the prod guarantees
below hold.

## Configuration and secrets

Non-secret settings (`APP_ENV`, `PORT`, `HOST`, `LOG_LEVEL`, `config.extraEnv`) go into a ConfigMap loaded with
`envFrom`. A `checksum/config` pod annotation rolls the pods when it changes, because env vars are only read at start.

`DATABASE_URL` is the only secret. **The chart never renders a Secret and no values file holds a secret value.** It
only references an existing Secret by name:

```yaml
secret:
  existingSecret: tdb-bookings-db   # empty = no Secret referenced, the service runs on sample data
  databaseUrlKey: DATABASE_URL
```

The pod gets it through `env[].valueFrom.secretKeyRef`, so the value goes from the API server to the kubelet and never
passes through Helm, a values file or git. The schema also refuses `DATABASE_URL` in `config.extraEnv`.

**Real environments:** External Secrets Operator syncs the RDS credentials that AWS Secrets Manager generates (P4)
into that Secret. ESO reads Secrets Manager with an IRSA role that can only `GetSecretValue` on that one secret.
Example (documentation only, not a chart template: the ExternalSecret belongs to the platform, and the chart must
also work with any other way of creating the Secret):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: tdb-bookings-db
  namespace: tdb-prod
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager            # SecretStore pointing at Secrets Manager in ap-south-1 via IRSA
  target:
    name: tdb-bookings-db                # = secret.existingSecret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        DATABASE_URL: "postgresql://{{ .username }}:{{ .password | urlquery }}@<rds-endpoint>:5432/bookings?sslmode=require"
  data:
    - secretKey: username
      remoteRef: { key: <rds-master-user-secret-arn>, property: username }
    - secretKey: password
      remoteRef: { key: <rds-master-user-secret-arn>, property: password }
```

A rotated password reaches running pods on the next rollout (env vars are read at start): run
`kubectl rollout restart`, or add Stakater Reloader to restart on Secret change.

**Locally:** create the Secret by hand; the value never touches a file in the repo:

```bash
kubectl -n tdb-prod create secret generic tdb-bookings-db \
  --from-literal=DATABASE_URL="postgresql://app:$(openssl rand -hex 16)@postgres.invalid:5432/bookings"
```

## Why releases do not cause downtime

| Mechanism | Effect |
|---|---|
| `RollingUpdate` `maxUnavailable: 0`, `maxSurge: 25%` | A serving pod is only removed after its replacement is Ready. Capacity never drops below the current count. |
| `startupProbe` then `readinessProbe` on `/health` | A new pod gets traffic only once it answers; slow starts are not killed by liveness. `/health` does not touch the database, so a DB outage never restarts pods. |
| `minReadySeconds` (10 s in prod) | A pod that crashes right after becoming Ready stops the rollout instead of replacing the next pod. |
| `preStop` sleep (10 s in prod), then SIGTERM | The pod is removed from Endpoints first; it keeps serving while kube-proxy and the load balancer catch up. Only then does uvicorn get SIGTERM and finish in-flight requests. |
| `terminationGracePeriodSeconds` (30) > preStop | Leaves 20 s for uvicorn's graceful shutdown before SIGKILL. The chart refuses a grace period ≤ the preStop sleep. |
| `helm upgrade --atomic` | A release whose pods never become Ready is rolled back automatically. `revisionHistoryLimit` keeps old ReplicaSets for `helm rollback`. |
| No `replicas` field when the HPA is on | An upgrade never resets the count the HPA chose (e.g. from 8 back to 3 during peak). |

Known edge: because the HPA owns `replicas`, a brand-new Deployment starts at 1 pod and the HPA raises it to
`minReplicas` within one sync (~15 s). That only affects the first install. Turning autoscaling on for an existing
release has the same one-sync dip (Helm removes the field); do that change outside peak hours.

The preStop hook is `exec: ["sleep", "N"]`. The native `lifecycle.preStop.sleep` action would not need a binary, but
it is only GA from Kubernetes 1.34 (beta, on by default, from 1.30). The image is `python:3.13-slim` (Debian), which
ships `/bin/sleep`, so the exec form works on every supported version and with the read-only root filesystem.

## Why it scales and survives node drains

- **Load:** `autoscaling/v2` HPA, 3–10 replicas in prod, on CPU (70 % of the request) and memory (80 %). Scales up
  fast (double or +2 pods every 30 s) and down slowly (5-minute stabilisation, at most 25 % per minute) to avoid
  flapping. Requests are set, so utilisation has a meaning. The HPA needs metrics-server in the cluster.
- **Drain:** PodDisruptionBudget `maxUnavailable: 1`: `kubectl drain` and node upgrades evict one pod at a time and wait
  until its replacement is Ready. `unhealthyPodEvictionPolicy: AlwaysAllow` lets a crash-looping pod be evicted so it
  never blocks a drain. The chart refuses a PDB that could take every pod (`maxUnavailable` ≥ minimum replicas); the schema refuses 0, which would block every drain.
- **Placement:** `topologySpreadConstraints`: across `kubernetes.io/hostname` hard (`DoNotSchedule`), across
  `topology.kubernetes.io/zone` soft (`ScheduleAnyway`, so a zone short of capacity never blocks scheduling).
  `nodeTaintsPolicy: Honor` keeps cordoned nodes (the one being drained) and the tainted control plane out of the
  skew maths; without it they count as empty domains and the replacement pod stays Pending.

## Pod security

Meets the Kubernetes **restricted** Pod Security Standard: `runAsNonRoot`, UID/GID 10001 (the image's user),
`seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, all capabilities dropped,
`readOnlyRootFilesystem: true` with a size-limited `emptyDir` at `/tmp`. The ServiceAccount has
`automountServiceAccountToken: false` (the service never calls the Kubernetes API). `enableServiceLinks: false` keeps
Docker-link env vars out of the process environment.

Resources: CPU and memory requests, a memory limit, **no CPU limit** by default. A CPU limit causes CFS throttling,
which shows up as tail latency even when the node has idle CPU; the request already guarantees the pod its share and
is what the HPA measures against. Set `resources.limits.cpu` if a namespace policy requires one.

NetworkPolicy (prod): ingress only to the `http` port, only from the VPC CIDR (ALB with IP targets), the `monitoring`
namespace (Prometheus) and pods labelled `tdb-bookings/client: <fullname>` (the `helm test` pod). Egress only to
cluster DNS and PostgreSQL 5432 inside the VPC. `10.0.0.0/16` in `values-prod.yaml` must equal the VPC CIDR in
`infra/terraform`.

## Values

| Key | Default | Description |
|---|---|---|
| `replicaCount` | `1` | Pods when autoscaling is off (prod: 3). |
| `image.repository` | `ghcr.io/ashish-sharma-edstem-dev/tdb-devops-handson` | Image repository. |
| `image.tag` | `""` | e.g. `sha-<commit sha>`. One of tag/digest is required (schema). |
| `image.digest` | `""` | `sha256:…`; wins over the tag. Preferred for prod. |
| `image.pullPolicy` | `IfNotPresent` | Dev uses `Always` because it follows the moving `main` tag. |
| `imagePullSecrets` | `[]` | Registry pull Secrets, created out of band. |
| `serviceAccount.create` / `.name` / `.annotations` | `true` / `""` / `{}` | Annotations for IRSA if the app ever needs AWS APIs. |
| `config.appEnv` / `.logLevel` | `local` / `info` | `APP_ENV`, `LOG_LEVEL`. |
| `config.extraEnv` | `{}` | Extra non-secret env vars. `DATABASE_URL`, `PORT`, `APP_ENV`, `LOG_LEVEL` are rejected. |
| `containerPort` | `8080` | `PORT`; 1024–65535 (non-root cannot bind lower). |
| `secret.existingSecret` | `""` | Secret holding the DB URL. Empty = not referenced. |
| `secret.databaseUrlKey` | `DATABASE_URL` | Key in that Secret. |
| `service.type` / `.port` | `ClusterIP` / `80` | Service; targets the named port `http`. |
| `metrics.scrape` / `.path` | `true` / `/metrics` | `prometheus.io/*` pod annotations. |
| `probes.path` | `/health` | Startup, readiness and liveness path. |
| `probes.startup` / `.readiness` / `.liveness` | see `values.yaml` | Probe timings (period, timeout, thresholds). |
| `rollingUpdate.maxSurge` / `.maxUnavailable` | `25%` / `0` | Rollout. |
| `revisionHistoryLimit` | `5` (prod 10) | Old ReplicaSets kept. |
| `minReadySeconds` | `5` (prod 10) | Ready time before a pod counts as available. |
| `preStopSleepSeconds` | `5` (prod 10) | Endpoint-drain delay before SIGTERM. 0 disables the hook. |
| `terminationGracePeriodSeconds` | `30` | Must be greater than `preStopSleepSeconds`. |
| `resources` | req `100m`/`128Mi`, limit `256Mi` | Prod: req `250m`/`256Mi`, limit `512Mi`. |
| `autoscaling.enabled` | `false` | Prod: `true`. |
| `autoscaling.minReplicas` / `.maxReplicas` | `1` / `3` | Prod: `3` / `10`. |
| `autoscaling.targetCPUUtilizationPercentage` | `70` | % of the CPU request. |
| `autoscaling.targetMemoryUtilizationPercentage` | `0` (off) | Prod: `80`. |
| `autoscaling.behavior` | fast up, slow down | HPA `behavior` block. |
| `podDisruptionBudget.enabled` / `.maxUnavailable` | `false` / `1` | Prod: `true` / `1`. |
| `podDisruptionBudget.unhealthyPodEvictionPolicy` | `AlwaysAllow` | Unready pods never block a drain. |
| `topologySpread.enabled` / `.constraints` | `false` / zone + hostname | Selector is added by the chart. |
| `podSecurityContext` / `securityContext` | restricted | Schema forbids `runAsNonRoot: false`, privilege escalation, `privileged`. |
| `tmpSizeLimit` | `64Mi` | Writable `/tmp`. |
| `networkPolicy.enabled` | `false` | Prod: `true`. |
| `networkPolicy.allowClientLabel` | `true` | Admit pods labelled `tdb-bookings/client: <fullname>`. |
| `networkPolicy.ingressFrom` | `[]` | NetworkPolicyPeers allowed to the `http` port. |
| `networkPolicy.egress.enabled` / `.rules` | `false` / `[]` | Restrict egress to DNS + these rules. |
| `ingress.enabled` / `.className` / `.annotations` / `.hosts` / `.tls` | off | Optional Ingress. |
| `podAnnotations`, `podLabels`, `nodeSelector`, `tolerations`, `affinity`, `priorityClassName` | empty | Usual scheduling hooks. |
| `tests.enabled` | `true` | `helm test` pod (uses the service image's Python, no extra image). |

## Local deploy on kind (prod values)

Proves the prod settings on a real scheduler: 3 replicas spread over 3 zones, a drain held by the PDB, and a rolling
upgrade with zero failed requests. Needs Docker, kind, kubectl, helm. Everything runs against the local `kind-tdb`
context only.

```bash
# 1. Cluster: control plane + 3 workers labelled zone-a/b/c.
kind create cluster --name tdb --config charts/tdb-bookings/ci/kind-config.yaml
kubectl config use-context kind-tdb
kubectl get nodes -L topology.kubernetes.io/zone

# 2. Image: build from the repo's Dockerfile and load it into the kind nodes (no registry needed).
docker build -t tdb-bookings:local .
kind load docker-image tdb-bookings:local --name tdb

# 3. Namespace enforcing the restricted Pod Security Standard, plus the DB Secret the prod values expect.
kubectl create namespace tdb-prod
kubectl label namespace tdb-prod pod-security.kubernetes.io/enforce=restricted
kubectl -n tdb-prod create secret generic tdb-bookings-db \
  --from-literal=DATABASE_URL="postgresql://app:$(openssl rand -hex 16)@postgres.invalid:5432/bookings"

# 4. Install with the prod values and the local image.
helm upgrade --install tdb-bookings charts/tdb-bookings -n tdb-prod \
  -f charts/tdb-bookings/values-prod.yaml \
  --set image.repository=tdb-bookings --set image.tag=local --set image.allowMutableTag=true \
  --wait --timeout 5m
kubectl -n tdb-prod rollout status deployment/tdb-bookings
# The HPA (not the Deployment) sets the count to 3, one sync after install:
kubectl -n tdb-prod wait deployment/tdb-bookings --for=jsonpath='{.status.availableReplicas}'=3 --timeout=2m
kubectl -n tdb-prod get pods -o wide            # 3 pods, one per worker
kubectl -n tdb-prod get hpa,pdb                 # HPA min 3 / max 10; PDB min available 2, allowed disruptions 1
helm -n tdb-prod test tdb-bookings
```

kind has no metrics-server, so the HPA shows `<unknown>` targets; it still enforces `minReplicas: 3`. To see it scale,
install metrics-server with `--kubelet-insecure-tls`.

**Traffic generator.** An in-cluster client that calls `/bookings` every 50 ms and counts failures. It carries the
client label so the NetworkPolicy admits it, and the restricted security context so Pod Security admits it:

```bash
kubectl -n tdb-prod apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: load
  labels: { tdb-bookings/client: tdb-bookings }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: load
      image: tdb-bookings:local
      imagePullPolicy: IfNotPresent
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      command:
        - python
        - -c
        - |
          import time, urllib.request
          ok = err = 0
          end = time.time() + 300
          while time.time() < end:
              try:
                  with urllib.request.urlopen("http://tdb-bookings/bookings", timeout=2) as r:
                      ok += r.status == 200
                      err += r.status != 200
              except Exception as e:
                  err += 1
                  print("ERROR", e, flush=True)
              time.sleep(0.05)
          print(f"ok={ok} errors={err}", flush=True)
EOF
```

**5. Rolling upgrade under load.** While `load` runs, change the config (new ConfigMap checksum → new ReplicaSet):

```bash
helm upgrade tdb-bookings charts/tdb-bookings -n tdb-prod \
  -f charts/tdb-bookings/values-prod.yaml \
  --set image.repository=tdb-bookings --set image.tag=local --set image.allowMutableTag=true \
  --set config.extraEnv.RELEASE_MARKER=v2 --wait
kubectl -n tdb-prod rollout status deployment/tdb-bookings
```

**6. Drain a node under load, with the PDB holding.** Draining two workers at once: the PDB lets one pod go, then
makes the second drain wait (`Cannot evict pod as it would violate the pod's disruption budget`) until the
replacement is Ready.

```bash
kubectl -n tdb-prod get pods -o wide
# --pod-selector: evict only the service's pods. Without it, drain refuses the node that hosts the bare `load`
# pod (no controller) and that node is never drained.
kubectl drain tdb-worker  --ignore-daemonsets --delete-emptydir-data --pod-selector app.kubernetes.io/name=tdb-bookings &
kubectl drain tdb-worker2 --ignore-daemonsets --delete-emptydir-data --pod-selector app.kubernetes.io/name=tdb-bookings
wait
kubectl -n tdb-prod get pods -o wide            # all 3 Running on tdb-worker3; PDB never below 2 available
kubectl uncordon tdb-worker tdb-worker2
# Kubernetes does not move pods back after uncordon; restart to re-spread them across zones.
kubectl -n tdb-prod rollout restart deployment/tdb-bookings
```

**Result:** `kubectl -n tdb-prod logs -f load` ends with `ok=<n> errors=0` once the 300 s are up.

**Clean up:**

```bash
kind delete cluster --name tdb
```
