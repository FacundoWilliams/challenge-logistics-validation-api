# ══════════════════════════════════════════════════════════════════════════════
#  Dockerfile — Multistage build for the Logistics Validation API
#  Base image: python:3.12-slim (Debian bookworm-slim)
#
#  Stages:
#    1. builder  — installs dependencies into an isolated prefix so
#                  only the wheel artifacts (no pip/setuptools/cache)
#                  are copied into the final image.
#    2. runner   — minimal runtime image, non-root user, no build tools.
#
#  Security highlights:
#    • No root process at runtime (USER appuser).
#    • pip cache discarded in the builder stage (--no-cache-dir).
#    • Only the installed packages directory is copied (not the entire
#      builder filesystem), minimising the attack surface.
#    • No SUID binaries are introduced because we use a slim base.
# ══════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 1 — builder
#  Purpose: install Python dependencies into /install so the final
#           image never needs pip, wheel, or a compiler.
# ─────────────────────────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build

# Copy only the dependency manifest first to leverage Docker layer caching:
# requirements.txt rarely changes, so this layer is reused on code-only changes.
COPY requirements.txt .

RUN pip install \
        --no-cache-dir \
        --upgrade pip \
    && pip install \
        --no-cache-dir \
        --prefix=/install \
        -r requirements.txt


# ─────────────────────────────────────────────────────────────────────────────
#  STAGE 2 — runner
#  Purpose: lean production image with no build artefacts.
# ─────────────────────────────────────────────────────────────────────────────
FROM python:3.12-slim AS runner

# ── OS hardening ──────────────────────────────────────────────────────────────
# Update base packages to pick up security patches available at build time.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Non-root user ─────────────────────────────────────────────────────────────
# Running as root inside a container is a CIS Docker Benchmark finding.
# Creating a dedicated user with no shell and no home directory limits
# the blast radius of a container escape.
RUN groupadd --system appgroup \
    && useradd  --system \
                --gid appgroup \
                --no-create-home \
                --shell /sbin/nologin \
                appuser

# ── Python packages from builder ──────────────────────────────────────────────
COPY --from=builder /install /usr/local

# ── Application source ────────────────────────────────────────────────────────
WORKDIR /app
COPY app/ ./app/

# Transfer ownership BEFORE switching user so the process can read its own files.
RUN chown -R appuser:appgroup /app

USER appuser

# ── Runtime configuration ─────────────────────────────────────────────────────
# Port is documented here for visibility; the actual binding is done in
# docker-compose.yml. Uvicorn listens on 0.0.0.0 so Docker networking works.
EXPOSE 8000

# ── Healthcheck ───────────────────────────────────────────────────────────────
# Docker-native liveness probe. The compose healthcheck mirrors this.
HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c \
        "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" \
    || exit 1

# ── Entrypoint ────────────────────────────────────────────────────────────────
# - --no-access-log  : Access logging is handled by Nginx upstream; avoid
#                      duplicate log lines in the container stdout.
# - --workers 1      : Single worker inside the container; scale horizontally
#                      via Compose replicas or Kubernetes HPA instead.
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--no-access-log", \
     "--workers", "1"]
