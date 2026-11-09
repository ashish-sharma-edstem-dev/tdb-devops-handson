# BookingsMetricsAbsent

| | |
|---|---|
| Severity | **page** |
| Service | `tdb-bookings` |
| Rule | [`monitoring/prometheus/rules/bookings-slo.yaml`](../../monitoring/prometheus/rules/bookings-slo.yaml) |

## What this alert means

For 10 minutes Prometheus has had either no healthy scrape target for job `tdb-bookings`
(`up{job="tdb-bookings"} == 1` is empty) or no booking request series
(`http_request_duration_seconds_count{route=~"/bookings(/.*)?"}`). `/health` series do not count. The app
creates the `GET /bookings` 2xx and 5xx series at startup with value 0, so an idle but healthy pod does not
trigger this alert; booking traffic that stops is `BookingsNoTraffic` instead.

Every SLO alert is built on that histogram. Without it the error ratios are empty and **no burn-rate alert can fire**,
so we are blind. Either the service is down, or the monitoring of it is broken. Both need a human now.

## How to check

1. Prometheus → **Status → Targets**, job `tdb-bookings`: is the target listed? What is the scrape error
   (connection refused, timeout, 404 on `/metrics`)?
2. Is the service up?

   ```sh
   NS=tdb-prod   # Helm namespace: tdb-prod (production) or tdb-dev
   kubectl get deploy,pods -n "$NS" -l app.kubernetes.io/name=tdb-bookings
   kubectl get events -n "$NS" --sort-by=.lastTimestamp | tail -20
   kubectl port-forward -n "$NS" deploy/tdb-bookings 8080:8080 &
   sleep 2   # give the port-forward time to listen
   curl -s localhost:8080/health
   curl -s localhost:8080/metrics | grep -c 'http_request_duration_seconds_count{.*route="/bookings"'
   kill %1
   ```

3. Did a release change the metrics? A renamed metric, removed label or moved `/metrics` path breaks the rules
   silently. Compare `helm history` and the last merged PRs.
4. Did discovery change? The pod template must keep its `prometheus.io/scrape: "true"`, `prometheus.io/port: "8080"`
   and `prometheus.io/path: /metrics` annotations, and the scrape config must still set `job="tdb-bookings"`
   for these pods (see the relabel in the [README](README.md#required-scrape-configuration)). A NetworkPolicy must allow Prometheus to reach port 8080.
5. Is Prometheus itself healthy (its own targets, disk, restarts)? If Prometheus is down this alert cannot fire either;
   that case is covered by the Alertmanager watchdog / dead-man's switch, not by this rule.

## What to do

- Service down → follow [BookingsErrorBudgetFastBurn → What to do](BookingsErrorBudgetFastBurn.md#what-to-do)
  (roll back a bad release, fix crash-looping pods).
- Service up but not scraped → fix the scrape path (annotations, NetworkPolicy, job name). Until fixed, watch the
  service by hand (ALB 5xx and latency in CloudWatch).
- Metric renamed by a release → roll back, or update the rules **and** their unit tests in the same PR.

## Verify it is resolved

`up{job="tdb-bookings"} == 1` returns one series per pod and `slo:bookings_request_errors:ratio_rate5m` has a value
again.
