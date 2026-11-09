"""Prometheus instrumentation for the SLO "99.9% of booking requests succeed in under 1 s".

One histogram gives both halves of the SLI:

- total requests  = ``http_request_duration_seconds_count``
- good requests   = ``http_request_duration_seconds_bucket{le="1.0", status_class!="5xx"}``

so latency and errors are always read from the same observation and can never drift apart. A
separate ``http_requests_total`` counter would duplicate ``_count`` exactly, so it is not exported.

Prometheus buckets are inclusive, so "under 1 s" is measured as ``<= 1 s``: a request of exactly
1.000 s counts as good (docs/adr/0005-slo-alerting.md).

Assumes one uvicorn worker per container (scaling is done with pod replicas, not workers), so the
``prometheus_client`` multiprocess mode is not needed.
"""

import time
from typing import Final

from prometheus_client import CollectorRegistry, Histogram
from starlette.types import ASGIApp, Message, Receive, Scope, Send

METRICS_PATH: Final = "/metrics"

# Route label for requests no route matched (404s). Using the raw path instead would let any client
# create unbounded label values (one series per scanned URL).
UNMATCHED_ROUTE: Final = "unmatched"

# HTTP methods recorded as-is; anything else (e.g. a scanner sending "FOO") becomes OTHER, so
# clients cannot create unbounded method label values.
KNOWN_METHODS: Final = frozenset({"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})
OTHER_METHOD: Final = "OTHER"

# Booking series created at startup with zero values, so an idle fresh deploy already exports them
# and the alert rules can tell "no booking traffic yet" from "booking metrics missing".
PREINITIALISED_SERIES: Final = (
    ("GET", "/bookings", "2xx"),
    ("GET", "/bookings", "5xx"),
)

# 1.0 must be an exact bucket boundary: the SLO threshold is read from the le="1.0" bucket.
# 0.75 and 2.5 around it show how close requests are to the threshold.
DURATION_BUCKETS: Final = (0.025, 0.05, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 10.0)


def new_request_histogram(registry: CollectorRegistry) -> Histogram:
    """Create the request histogram in ``registry``, with the booking series pre-created."""
    histogram = Histogram(
        "http_request_duration_seconds",
        "Time from receiving an HTTP request to sending the last byte of the response.",
        labelnames=("method", "route", "status_class"),
        buckets=DURATION_BUCKETS,
        registry=registry,
    )
    for method, route, status in PREINITIALISED_SERIES:
        histogram.labels(method=method, route=route, status_class=status)
    return histogram


def method_label(method: str) -> str:
    """Return ``method`` if it is a standard HTTP method, otherwise ``"OTHER"``."""
    return method if method in KNOWN_METHODS else OTHER_METHOD


def status_class(status_code: int) -> str:
    """Map an HTTP status code to its class label, e.g. 404 -> ``"4xx"``."""
    return f"{status_code // 100}xx"


def route_template(scope: Scope) -> str:
    """Return the matched route template (``/bookings/{id}``), never the raw request path."""
    path = getattr(scope.get("route"), "path", None)
    return path if isinstance(path, str) and path else UNMATCHED_ROUTE


class PrometheusMiddleware:
    """Pure ASGI middleware that observes every HTTP request in ``histogram``.

    The duration covers the whole ASGI call, so it would include background tasks run after the
    response is sent; the app has none today. If one is added, it will count against the 1 s SLI.

    It sits outside FastAPI's exception handling, so an exception that escapes the app is still
    observed (as 5xx, which is what the server error middleware will answer) and then re-raised.
    Scrapes of ``/metrics`` are not observed: they are not user traffic and would dilute the SLI.
    """

    def __init__(self, app: ASGIApp, histogram: Histogram) -> None:
        self.app = app
        self.histogram = histogram

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] == METRICS_PATH:
            await self.app(scope, receive, send)
            return

        status_code = 500
        start = time.perf_counter()

        async def send_wrapper(message: Message) -> None:
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = int(message["status"])
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        except BaseException:
            # Counted as a failure even if a status line was already sent: the response is broken.
            status_code = 500
            raise
        finally:
            # The router fills scope["route"] in place, so it is known once the app has run.
            self.histogram.labels(
                method=method_label(scope["method"]),
                route=route_template(scope),
                status_class=status_class(status_code),
            ).observe(time.perf_counter() - start)
