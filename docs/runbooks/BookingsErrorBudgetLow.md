# BookingsErrorBudgetLow

| | |
|---|---|
| Severity | **ticket** |
| Service | `tdb-bookings` |
| SLO | 99.9% of booking requests succeed (not 5xx) **and** finish in ≤ 1 s, over 30 days |
| Rule | [`monitoring/prometheus/rules/bookings-slo.yaml`](../../monitoring/prometheus/rules/bookings-slo.yaml) |

## What this alert means

More than 75% of the 30-day error budget is spent: over the last 30 days more than 0.075% of booking requests failed
or took longer than 1 s (the SLO allows 0.1%). Only a quarter of the budget is left. If `{{ $value }}` is above
0.1%, the SLO is **already missed** for the current 30-day window.

This is a safety net for slow, steady loss that never crosses the burn-rate thresholds, and for the sum of several
earlier incidents. It fires after the condition holds for 1 hour and clears as old bad requests age out of the
30-day window.

## How to check

```promql
slo:bookings_request_errors:ratio_rate30d            # ratio over the window
1 - slo:bookings_request_errors:ratio_rate30d / 0.001 # budget left (0.25 = a quarter left)
slo:bookings_request_errors:ratio_rate1d             # is it still burning today?
```

Graph `slo:bookings_request_errors:ratio_rate1d` over 30 days: one or two spikes means past incidents used the
budget; a flat raised line means a constant background error or latency problem (see
[BookingsErrorBudgetSlowBurn](BookingsErrorBudgetSlowBurn.md)).

## What to do

- Apply the error-budget policy: freeze risky changes (large refactors, infra migrations) for this service until the
  budget recovers; only ship fixes and low-risk changes.
- If it is still burning today, find and fix the cause as in the slow-burn runbook.
- Make sure each incident that spent budget has a postmortem with action items.

## Verify it is resolved

The alert clears by itself once `slo:bookings_request_errors:ratio_rate30d` drops below `0.00075`, as the bad period
leaves the 30-day window. It cannot be "fixed" faster; the goal is to stop adding to it.
