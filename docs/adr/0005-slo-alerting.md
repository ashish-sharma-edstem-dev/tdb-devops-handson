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
   counter: it would equal `_count`.
2. **Labels are bounded.** `route` is the route template (`/bookings/{id}`), or `unmatched` for 404s, never the raw
   path; `status_class` instead of the status code.
3. **Multi-window, multi-burn-rate alerts** (Google SRE Workbook, ch. 5) instead of static thresholds such as
   "error rate > 1% for 5 min". A static threshold either pages on short blips that cost little budget, or misses a
   steady 0.5% that misses the SLO within a week. Burn-rate alerts are tied to the budget: page at 14.4× (1 h + 5 min)
   and 6× (6 h + 30 min), ticket at 3× (1 d + 2 h) and 1× (3 d + 6 h). The short window makes the alert stop soon
   after a fix. A 30-day "75% of budget spent" ticket catches what is too slow for all of them.
4. **No data pages** (`BookingsMetricsAbsent`): every SLO alert is silent without metrics.
5. **Low-traffic guard on the page only**: no page below 100 requests/hour, where one failure is ≥ 1%.

## Assumptions

- `4xx` responses are client errors and count as good.
- One uvicorn worker per container (scale with replicas), so no `prometheus_client` multiprocess mode.
- One Prometheus per environment, scrape job named `tdb-bookings`, retention ≥ 30 days.

## Consequences

- Rules are unit-tested with `promtool test rules` in CI; changing a metric name or label needs the rules and tests
  changed in the same PR.
- The 30-day recording rule reads 30 days of samples every evaluation. Fine at this cardinality; at a larger scale
  it would be derived from shorter recorded windows.
- Latency is only judged at 1 s. A different threshold needs a new bucket boundary, and history before the change
  cannot be re-measured.
