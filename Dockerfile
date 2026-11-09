# Production image for the tdb-bookings service.
#
# Two stages share one pinned base, so the venv built in `builder` runs unchanged in `runtime`:
#   builder: installs the locked runtime dependencies with uv into /app/.venv
#   runtime: copies only that venv and app/, runs as UID/GID 10001
#
# Base images are pinned by digest, with the exact tag kept beside it so Dependabot can bump both.
# The python reference is written out in both FROM lines (not an ARG) because Dependabot does not
# resolve build args; keep the two identical.
# The same image runs in every environment: all configuration comes from environment variables
# at run time (see app/config.py). Nothing environment-specific is baked in.

# ghcr.io/astral-sh/uv:0.12.5, the uv release the lockfile was produced with
FROM ghcr.io/astral-sh/uv:0.12.5@sha256:e85be844203885286c60ffad8a858d48afb6c5a5c237ca0e67f12e74b8f174b1 AS uv

# ---------------------------------------------------------------------------------------------
# python:3.13.18-slim (Debian 13 trixie), multi-arch index digest
FROM python:3.13.18-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS builder

COPY --from=uv /uv /usr/local/bin/uv

# Compile .pyc at install time (the runtime filesystem is read-only), copy files out of the cache
# mount instead of hard-linking, and never let uv download its own Python: use the base image's.
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app

# Only the lock and project metadata are needed to resolve dependencies, so this layer is
# rebuilt only when dependencies change, not on every code change.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-dev --no-install-project

# ---------------------------------------------------------------------------------------------
# Same base as the builder, so the venv's interpreter path and ABI match exactly.
FROM python:3.13.18-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS runtime

# 1. Take the Debian security fix for zlib1g (CVE-2026-76844, CVE-2026-85091, both HIGH and
#    fixed in deb13u1) that the pinned base digest does not ship yet. Unpinned on purpose: Debian
#    drops superseded security builds from the archive, so an exact pin would break future builds.
#    Delete this step once the base digest carries the fix (Trivy will show it as gone).
# 2. Remove pip and ensurepip. Dependencies are installed by uv in the builder; an installer has
#    no job at run time, and pip's vendored urllib3/msgpack/setuptools carry 5 HIGH CVEs.
#    The `! python -c "import pip"` check fails the build if a base-image layout change ever
#    makes the rm a silent no-op.
# 3. Strip setuid/setgid bits (su, passwd, mount, ...): nothing in the image may gain privileges,
#    even where a runtime forgets --cap-drop / no-new-privileges.
# 4. Unprivileged system user with a fixed numeric UID/GID, no home directory, no login shell.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install --yes --no-install-recommends --only-upgrade zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/local/lib/python3.13/site-packages/pip \
              /usr/local/lib/python3.13/site-packages/pip-*.dist-info \
              /usr/local/lib/python3.13/ensurepip \
              /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip3.13 \
    && ! python -c "import pip" 2>/dev/null \
    && find / -xdev -type f -perm /6000 -exec chmod a-s {} + \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

# Code and dependencies stay owned by root, so the service cannot modify itself at run time.
COPY --from=builder /app/.venv /app/.venv
COPY app/ /app/app/

ENV PATH="/app/.venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Numeric so Kubernetes `runAsNonRoot` can verify it without resolving /etc/passwd.
USER 10001:10001

# Default port; override with PORT at run time.
EXPOSE 8080

# Uses the image's own Python, so no curl/wget is added. Exec form: no shell needed.
# ProxyHandler({}) ignores HTTP_PROXY/http_proxy: a local probe must never go through a proxy.
# Kubernetes ignores HEALTHCHECK and uses its own probes (Helm chart).
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import os, urllib.request as r; r.build_opener(r.ProxyHandler({})).open('http://127.0.0.1:%s/health' % os.environ.get('PORT', '8080'), timeout=2)"]

# Exec form: Python is PID 1 and receives SIGTERM directly for a graceful uvicorn shutdown.
CMD ["python", "-m", "app.main"]

# Labels last, so CI-supplied values do not invalidate earlier layers.
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="tdb-bookings" \
      org.opencontainers.image.description="Minimal bookings web service (FastAPI)" \
      org.opencontainers.image.source="https://github.com/ashish-sharma-edstem-dev/tdb-devops-handson" \
      org.opencontainers.image.licenses="NOASSERTION" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"
