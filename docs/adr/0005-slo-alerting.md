# ADR 0005: Alert on error-budget burn rate, from one request histogram

- Status: accepted
- Date: 2026-11-09
- Problem: P5 (alerts and runbook)

## Context

Target: 99.9% of booking requests succeed in under 1 s, over 30 days. The on-call engineer must be warned before the
target is missed, without being paged for noise.

## Decision

1. **One histogram is the whole SLI.** `http_request_duration_seconds{method,route,status_class}` with a bucket at
   exactly `1.0`. Good = `le="1.0"` bucket with `status_class!="5xx"`; total = `_count`. Errors and latency come from
   the same observation, so they cannot disagree, and a slow `200` burns budget like a `500`. No separate request
   counter: it would equal `_count`. The good-request numerator is zero-filled (`or on (job) 0 * total`), so when
   every request is a 5xx (no non-5xx series exist) the error ratio is 100% instead of empty.
2. **Labels are bounded.** `route` is the route template (`/bookings/{id}`), or `unmatched` for 404s, never the raw
   path; `status_class` instead of the status code; `method` is one of GET, HEAD, POST, PUT, PATCH, DELETE,
   OPTIONS, or `OTHER`.
3. **Multi-window, multi-burn-rate alerts** (Google SRE Workbook, ch. 5) instead of static thresholds such as
   "error rate > 1% for 5 min". A static threshold either pages on short blips that cost little budget, or misses a
   steady 0.5% that misses the SLO within a week. Burn-rate alerts are tied to the budget: page at 14.4× (1 h + 5 min)
   and 6× (6 h + 30 min), ticket at 3× (1 d + 2 h) and 1× (3 d + 6 h). The short window makes the alert stop soon
   after a fix. A 30-day "75% of budget spent" ticket catches what is too slow for all of them.
4. **No data is alerted on, in two ways**, because every burn alert is silent when there is nothing to divide:
   - `BookingsMetricsAbsent` (page): no healthy target, or no **booking** request series (`/health` series do not
     count). The app pre-creates the `GET /bookings` 2xx and 5xx series at 0 on startup, so an idle healthy pod
     is not "absent".
   - `BookingsNoTraffic` (ticket): booking traffic stopped for 45 min (15-min rate 0, `for: 30m`) after there was
     some in the last day. Counters persist and `/health` keeps the target up, so the SLI is 0/0 = NaN and neither
     the burn alerts nor the absence alert can see this. Ticket, not page: without a traffic baseline a quiet
     night looks like a routing outage. The "traffic in the last day" guard means an idle fresh deploy never
     fires it; the price is that it resolves itself after a day of no traffic.
5. **Low-traffic guard on the page only**: no page below 100 requests/hour, where one failure is ≥ 1%.

## Assumptions

- `4xx` responses are client errors and count as good.
- One uvicorn worker per container (scale with replicas), so no `prometheus_client` multiprocess mode.
- One Prometheus per environment, retention ≥ 30 days.
- The scrape config sets `job="tdb-bookings"` on the bookings pods. The Helm chart only sets `prometheus.io/*`
  annotations, so this relabel is a **required deployment step**; the snippet is in
  [`docs/runbooks/README.md`](../runbooks/README.md#required-scrape-configuration).
- "Under 1 s" is read as **≤ 1 s**: the `le="1.0"` bucket includes a request of exactly 1.000 s. Accepted, because
  the difference is a single float boundary.
- The middleware times the whole ASGI call, which would include background tasks run after the response. The
  app has none today; adding one would count its time against the 1 s SLI.

## Consequences

- Rules are unit-tested with `promtool test rules` in CI; changing a metric name or label needs the rules and tests
  changed in the same PR.
- The 30-day recording rule reads 30 days of samples every evaluation. Fine at this cardinality; at a larger scale
  it would be derived from shorter recorded windows.
- Latency is only judged at 1 s. A different threshold needs a new bucket boundary, and history before the change
  cannot be re-measured.
