# BookingsNoTraffic

| | |
|---|---|
| Severity | **ticket** |
| Service | `tdb-bookings` |
| Rule | [`monitoring/prometheus/rules/bookings-slo.yaml`](../../monitoring/prometheus/rules/bookings-slo.yaml) |

## What this alert means

No booking request (`route=~"/bookings(/.*)?"`) has reached the service for at least 45 minutes (15-minute rate
is 0, held for 30 minutes), although there was booking traffic in the last day. The target is still scraped, so
`BookingsMetricsAbsent` stays quiet, and with no requests the SLI is 0/0, so **no burn-rate alert can fire**.
The usual cause is something in front of the pods: ingress, ALB, DNS or a client release.

It is a ticket, not a page, because a quiet hour (night, weekend) looks the same as a routing outage without a
traffic baseline. If users report errors, treat it as an outage and page yourself. An idle fresh deploy that never
had traffic does not fire it.

## How to check

1. Is it expected? Maintenance window, client freeze, a weekend? Compare with the same time last week:

   ```promql
   sum(rate(http_request_duration_seconds_count{job="tdb-bookings", route=~"/bookings(/.*)?"}[15m] offset 1w))
   ```

2. Do requests reach the pods at all? Only `/health` rising means the pods are fine and traffic stops upstream:

   ```promql
   sum by (route) (rate(http_request_duration_seconds_count{job="tdb-bookings"}[15m]))
   ```

3. Try the public endpoint and the service directly:

   ```sh
   NS=tdb-prod   # Helm namespace: tdb-prod (production) or tdb-dev
   curl -si https://<public-host>/bookings | head -1
   kubectl get ingress,svc,endpoints -n "$NS"
   kubectl port-forward -n "$NS" deploy/tdb-bookings 8080:8080 &
   sleep 2   # give the port-forward time to listen
   curl -si localhost:8080/bookings | head -1
   kill %1
   ```

## What to do

- Public endpoint fails, pod answers → fix the ingress / ALB / DNS / Service selector (check recent infra changes).
- Pod does not answer either → follow [BookingsErrorBudgetFastBurn → What to do](BookingsErrorBudgetFastBurn.md#what-to-do).
- Traffic is really zero (expected quiet period) → resolve the ticket and note it.

## Verify it is resolved

`sum(rate(http_request_duration_seconds_count{job="tdb-bookings", route=~"/bookings(/.*)?"}[5m])) > 0` and
`slo:bookings_request_errors:ratio_rate5m` has a value again.
