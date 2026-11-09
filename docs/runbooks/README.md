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
| `BookingsMetricsAbsent` | page | no healthy target or no request metrics for 10 min | [short](BookingsMetricsAbsent.md) |

`page` = wake someone up. `ticket` = handle in working hours.

Every runbook follows the same order: **what it means → how to check → what to do → how to verify**.
