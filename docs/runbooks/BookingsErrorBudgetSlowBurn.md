# BookingsErrorBudgetSlowBurn

| | |
|---|---|
| Severity | **ticket** (working hours, no page) |
| Service | `tdb-bookings` |
| SLO | 99.9% of booking requests succeed (not 5xx) **and** finish in ≤ 1 s, over 30 days |
| Rule | [`monitoring/prometheus/rules/bookings-slo.yaml`](../../monitoring/prometheus/rules/bookings-slo.yaml) |

## What this alert means

A small but steady share of booking requests is failing or slower than 1 s, enough to run out the month's error budget
(0.1% of requests) before the 30 days are over. Nothing is on fire, but left alone the SLO will be missed.

| Condition | Burn rate | Error ratio above | Budget spent before it fires | Budget gone in |
|---|---|---|---|---|
| last **1 d** and last **2 h** | 3× | 0.3% | 10% in 1 day | 10 days |
| last **3 d** and last **6 h** | 1× | 0.1% | 10% in 3 days | 30 days |

Must hold for 15 minutes. `{{ $value }}` is the error ratio over the long window.

Typical causes: one slow endpoint or query, a small fraction of requests timing out, one unhealthy pod or node,
a slow memory leak causing periodic restarts, latency creeping up as data grows.

## How to check

Use the queries in [BookingsErrorBudgetFastBurn → How to check](BookingsErrorBudgetFastBurn.md#how-to-check), but
with longer windows (`[1h]` or `[6h]` instead of `[5m]`):

```promql
slo:bookings_request_errors:ratio_rate1d
sum by (route, status_class) (rate(http_request_duration_seconds_count{job="tdb-bookings"}[6h]))
histogram_quantile(0.99, sum by (le, route) (rate(http_request_duration_seconds_bucket{job="tdb-bookings"}[1h])))
1 - slo:bookings_request_errors:ratio_rate30d / 0.001
```

Set `NS=tdb-prod` (or `tdb-dev`; Helm release `tdb-bookings`) for the commands below.

1. Errors or latency? Split as in step 1 of the fast-burn runbook.
2. When did it start? Graph `slo:bookings_request_errors:ratio_rate1h` over the last 7 days and line it up with
   `helm history tdb-bookings -n "$NS"`.
3. One pod / node / zone, or all? Group the error ratio `by (instance)`.
4. Restarts: `kubectl get pods -n "$NS" -l app.kubernetes.io/name=tdb-bookings` (a rising `RESTARTS` count).

## What to do

- Open a ticket with the findings, owned by the service team, due well before the budget runs out (see the
  budget-left query).
- Caused by a release → revert or fix forward through a normal PR.
- Latency creeping up → profile the slow route, check DB query plans / Performance Insights, review resource requests
  and HPA limits.
- One bad pod → delete it (the Deployment replaces it). One bad node → cordon **and drain** it with
  `--pod-selector app.kubernetes.io/name=tdb-bookings` (cordon alone leaves the pods there); see the fast-burn runbook.
- If it gets worse it becomes `BookingsErrorBudgetFastBurn`, which pages.

## Verify it is resolved

`slo:bookings_request_errors:ratio_rate2h` and `_rate6h` back below `0.001`; the alert clears once the short window
(2 h / 6 h) is clean.
