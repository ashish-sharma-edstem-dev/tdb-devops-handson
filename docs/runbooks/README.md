# Runbooks

One runbook per alert. Every alert in
[`monitoring/prometheus/rules/bookings-slo.yaml`](../../monitoring/prometheus/rules/bookings-slo.yaml) links here
through its `runbook_url` annotation.

SLO: **99.9% of booking requests succeed (not 5xx) and finish in ≤ 1 s, over 30 days.** Error budget: 0.1% of
requests.

| Alert | Severity | Fires when | Runbook |
|---|---|---|---|
| `BookingsErrorBudgetFastBurn` | page | burn rate ≥ 14.4× over 1 h and 5 min, or ≥ 6× over 6 h and 30 min | [full](BookingsErrorBudgetFastBurn.md) |
| `BookingsErrorBudgetSlowBurn` | ticket | burn rate ≥ 3× over 1 d and 2 h, or ≥ 1× over 3 d and 6 h | [short](BookingsErrorBudgetSlowBurn.md) |
| `BookingsErrorBudgetLow` | ticket | more than 75% of the 30-day budget spent | [short](BookingsErrorBudgetLow.md) |
| `BookingsMetricsAbsent` | page | no healthy target or no booking request series for 10 min | [short](BookingsMetricsAbsent.md) |
| `BookingsNoTraffic` | ticket | no booking requests for 45 min although there was traffic in the last day | [short](BookingsNoTraffic.md) |

`page` = wake someone up. `ticket` = handle in working hours.

Every runbook follows the same order: **what it means → how to check → what to do → how to verify**.

Commands use `NS=tdb-prod` (production) or `NS=tdb-dev`; the Helm release is `tdb-bookings` in both.

## Required scrape configuration

Every rule selects `job="tdb-bookings"`. The Helm chart only sets the `prometheus.io/scrape`, `prometheus.io/port`
and `prometheus.io/path` pod annotations; it does not set the job. Deploying these rules therefore **requires** the
cluster Prometheus to label the bookings pods with that job, for example in a `kubernetes_sd_configs` scrape job
with `role: pod`:

```yaml
relabel_configs:
  # Keep only pods that opt in through the annotation.
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
    action: keep
    regex: "true"
  # Set job="tdb-bookings" for pods labelled app.kubernetes.io/name=tdb-bookings.
  - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
    regex: tdb-bookings
    target_label: job
    replacement: tdb-bookings
```

Without it the series carry the scrape job's own name, every rule matches nothing, and only `BookingsMetricsAbsent`
(through `up{job="tdb-bookings"}` being absent) fires.
