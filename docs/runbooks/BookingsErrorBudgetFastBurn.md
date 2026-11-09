# BookingsErrorBudgetFastBurn

| | |
|---|---|
| Severity | **page** (act now, any hour) |
| Service | `tdb-bookings` |
| SLO | 99.9% of booking requests succeed (not 5xx) **and** finish in ≤ 1 s, over 30 days |
| Rule | [`monitoring/prometheus/rules/bookings-slo.yaml`](../../monitoring/prometheus/rules/bookings-slo.yaml) |

## What this alert means

Too many booking requests are failing or are slow, and it is still happening now.

The SLO allows 0.1% of requests in 30 days to be bad. That allowance is the **error budget**. A request is bad if it
returns a 5xx **or** takes longer than 1 second. A slow `200` counts the same as a `500`. A `4xx` is not bad: it is
the client's mistake (bad input, unknown booking).

The **burn rate** is how fast we spend that budget compared with spending it evenly over 30 days. Burn rate 1 uses the
budget up in exactly 30 days. The alert fires on either condition:

| Condition | Burn rate | Error ratio above | Budget spent before it fires | Budget gone in, if it continues |
|---|---|---|---|---|
| last **1 h** and last **5 min** | 14.4× | 1.44% | 2% of the month's budget in 1 h | ~2 days (30 d ÷ 14.4 ≈ 50 h) |
| last **6 h** and last **30 min** | 6× | 0.6% | 5% of the month's budget in 6 h | 5 days |

The long window (1 h / 6 h) proves the problem is big enough to matter; the short window (5 min / 30 min) proves it is
still going on, so the alert clears soon after the problem is fixed. The condition must hold for 2 minutes. It does
not fire when the service had fewer than 100 requests in the last hour: at that volume one failed request is already
1%, and the slower ticket alerts still catch it.

The `{{ $value }}` in the alert is the error ratio over the long window (1 h or 6 h), e.g. `5%`.

## Impact

Users who open or list bookings get errors or wait more than a second. At 14.4× the whole month's budget is gone in
about two days; after that, any further problem means the 99.9% target is missed for the month.

## How to check

Open Prometheus (local stack: <http://localhost:9090>; production: the cluster's Prometheus/Grafana) and work through
these in order. Steps 1–3 take a couple of minutes and decide which branch of [What to do](#what-to-do) you are in.

Set these first (the names come from the Helm release and Terraform environment):

```sh
NS=tdb-bookings                       # Kubernetes namespace of the release
APP=app.kubernetes.io/name=tdb-bookings
DB_ID=tdb-bookings-prod               # RDS instance identifier (Terraform output)
```

### 1. Is it errors or latency?

Current error ratio (the SLI, 5-minute window):

```promql
slo:bookings_request_errors:ratio_rate5m
```

Share of requests that are **5xx**:

```promql
sum(rate(http_request_duration_seconds_count{job="tdb-bookings", route=~"/bookings(/.*)?", status_class="5xx"}[5m]))
/
sum(rate(http_request_duration_seconds_count{job="tdb-bookings", route=~"/bookings(/.*)?"}[5m]))
```

Share of requests that **did not fail but took longer than 1 s**:

```promql
(
  sum(rate(http_request_duration_seconds_count{job="tdb-bookings", route=~"/bookings(/.*)?", status_class!="5xx"}[5m]))
  -
  sum(rate(http_request_duration_seconds_bucket{job="tdb-bookings", route=~"/bookings(/.*)?", status_class!="5xx", le="1.0"}[5m]))
)
/
sum(rate(http_request_duration_seconds_count{job="tdb-bookings", route=~"/bookings(/.*)?"}[5m]))
```

The two add up to the SLI. Whichever is larger is your problem.

### 2. Where is it?

Requests per second by route and status class (look for a new route or a jump in `5xx`):

```promql
sum by (route, status_class) (rate(http_request_duration_seconds_count{job="tdb-bookings"}[5m]))
```

p50 / p99 latency by route:

```promql
histogram_quantile(0.99, sum by (le, route) (rate(http_request_duration_seconds_bucket{job="tdb-bookings"}[5m])))
histogram_quantile(0.50, sum by (le, route) (rate(http_request_duration_seconds_bucket{job="tdb-bookings"}[5m])))
```

Is it one pod or all of them? (One bad pod = node or pod problem; all pods = release, dependency or load.)

```promql
sum by (instance) (rate(http_request_duration_seconds_count{job="tdb-bookings", route=~"/bookings(/.*)?", status_class="5xx"}[5m]))
/
sum by (instance) (rate(http_request_duration_seconds_count{job="tdb-bookings", route=~"/bookings(/.*)?"}[5m]))
```

Did traffic jump? (Compare with the same time yesterday.)

```promql
sum(rate(http_request_duration_seconds_count{job="tdb-bookings"}[5m]))
sum(rate(http_request_duration_seconds_count{job="tdb-bookings"}[5m] offset 1d))
```

How much of the month's budget is left (1 = untouched, 0 = gone, negative = SLO missed):

```promql
1 - slo:bookings_request_errors:ratio_rate30d / 0.001
```

### 3. What changed?

Recent releases. A new revision in the last hour or two is the most likely cause:

```sh
helm history tdb-bookings -n "$NS" --max 5
kubectl rollout history deployment/tdb-bookings -n "$NS"
kubectl get deployment tdb-bookings -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Also check the last merged PRs and the CI publish runs on `main` (the image tag `sha-<commit>` maps to the commit).

### 4. Are the pods healthy?

```sh
kubectl get pods -n "$NS" -l "$APP" -o wide          # restarts, Pending, which nodes / zones
kubectl get events -n "$NS" --sort-by=.lastTimestamp | tail -30
kubectl describe pod -n "$NS" <pod>                  # OOMKilled, probe failures, image pull errors
kubectl logs -n "$NS" -l "$APP" --since=15m --tail=200 | grep -iE 'error|exception|timeout'
kubectl logs -n "$NS" <pod> --previous               # logs from before the last crash
kubectl top pods -n "$NS" -l "$APP"                  # CPU / memory near limits?
kubectl get hpa -n "$NS"                             # replicas at maxReplicas?
kubectl get nodes -L topology.kubernetes.io/zone     # NotReady nodes, one zone missing?
```

### 5. Is the database healthy? (read-only)

Once bookings are read from RDS, database trouble shows up as 5xx (connection errors) or slow requests.

```sh
aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,MultiAZ,AvailabilityZone,SecondaryAvailabilityZone]'
aws rds describe-events --source-type db-instance --source-identifier "$DB_ID" --duration 180
```

`describe-events` shows failovers, reboots, maintenance and storage-full events from the last 3 hours. In the AWS
console: RDS → the instance → **Monitoring** (CPU, `DatabaseConnections`, `ReadLatency`, `FreeStorageSpace`) and
**Performance Insights** (top SQL and wait events). Only read here; do not modify the instance from this runbook.

### 6. Is it the platform?

- AWS Health Dashboard for the region (an AZ or EKS/RDS incident).
- The load balancer: ALB target group health and `HTTPCode_ELB_5XX_Count` (errors the pods never saw).

## What to do

Work top-down; stop at the first branch that matches.

1. **A release went out shortly before the alert started** → roll back first, investigate after.

   ```sh
   helm history tdb-bookings -n "$NS"
   helm rollback tdb-bookings <previous-good-revision> -n "$NS" --wait --timeout 10m
   ```

   The chart's rolling update keeps the old pods serving until the new ones are ready, so a rollback is safe under
   load. Then open an issue / revert PR for the bad change. A rollback changes production: say in the incident channel
   that you are doing it.

2. **Pods are crash-looping, OOMKilled or failing readiness** (step 4).
   - OOMKilled → the memory limit is too low for current load or there is a leak. Roll back if it started with a
     release; otherwise raise `resources.limits.memory` through a values change and a normal release.
   - Image pull errors → registry or tag problem; roll back to the last revision that pulled.
   - Only pods on one node or one zone are bad → cordon that node (`kubectl cordon <node>`) so pods reschedule;
     replicas are spread across zones, so the rest keep serving.

3. **Errors are low but requests are slow** (step 1 says latency).
   - CPU near the limit and the HPA at `maxReplicas` → the service is under-scaled for the traffic. Raise
     `autoscaling.maxReplicas` (values change, normal release); if nodes are full, check the cluster autoscaler.
   - Traffic far above yesterday → check for a bot or a client retry loop (ALB access logs, WAF). Rate-limit or block
     at the edge rather than scaling into abuse.
   - Latency came with the database (step 5) → go to 4.

4. **The database is failing over or degraded** (step 5 shows a failover, reboot or high latency).
   - A Multi-AZ failover normally completes in 60–120 s; connections to the old primary fail and the app reconnects.
     Wait, and confirm `slo:bookings_request_errors:ratio_rate5m` comes down once `DBInstanceStatus` is `available`.
   - Still failing several minutes after the instance is `available` → the app may be holding stale connections;
     restart the pods one by one: `kubectl rollout restart deployment/tdb-bookings -n "$NS"`.
   - Storage full, CPU pinned or a runaway query → escalate to the database owner (below). Do not resize or modify
     RDS from this runbook.

5. **A whole AZ or AWS service is degraded** (step 6) → the platform is built to survive one AZ (three AZs, Multi-AZ
   RDS, pods spread across zones). Check that the remaining zones are serving and scaled up; follow AWS status and
   escalate to the platform owner.

6. **Nothing above matches** → escalate (below) with what you checked. Do not silence the alert to stop the noise;
   if you must acknowledge it, keep the incident open.

## Escalation

| When | Who |
|---|---|
| Not mitigated within 30 minutes, or the budget-left query is below 0.25 | Service owner (`@ashish-sharma-edstem-dev`, `.github/CODEOWNERS`) |
| Database failover not recovering, storage / CPU exhaustion | Database / platform owner |
| AZ or AWS regional problem | Platform owner; open an AWS support case |
| Customers affected for more than 15 minutes | Incident commander / product owner for customer communication |

Record what you saw and did, with times, in the incident channel as you go.

## Verify it is resolved

- `slo:bookings_request_errors:ratio_rate5m` is back below `0.001` and stays there for 15 minutes.
- The 5xx share and slow share from step 1 are both near 0.
- `kubectl get pods -n "$NS" -l "$APP"`: all Ready, restarts not increasing.
- The alert resolves by itself: the 5-minute window clears within minutes, the 30-minute window within about half an
  hour of the fix.

## After the incident

- Write a short blameless postmortem for every page: timeline, impact, budget spent (from the budget-left query before
  and after), root cause, action items with owners.
- Apply the error-budget policy: if more than 50% of the month's budget is gone, prioritise reliability work over
  features until it recovers; if the SLO was missed, review release frequency and testing for the next cycle.
- If this alert fired with no real user impact, tune it (windows, low-traffic guard), and add a case to
  `monitoring/prometheus/tests/bookings-slo.test.yaml` that covers the situation.
