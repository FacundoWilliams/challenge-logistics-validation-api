#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  scripts/start.sh
#  Start the full Logistics Validation API environment via Docker Compose.
#
#  Usage:
#    ./scripts/start.sh [--build] [--env-file <path>]
#
#  Options:
#    --build              Force a Docker image rebuild before starting.
#    --env-file <path>    Override the default .env file location.
#                         Defaults to <project_root>/.env if it exists,
#                         or <project_root>/.env.example as a fallback.
#
#  What this script does:
#    1. Validates that Docker and Compose are available.
#    2. Resolves the correct .env file.
#    3. Optionally rebuilds images.
#    4. Brings up all services in detached mode.
#    5. Polls the /health endpoint (via Nginx on port 80) until the
#       stack is ready, then prints a short summary.
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
COMPOSE_PROJECT="logistics"
HEALTH_URL="http://localhost/health"
HEALTH_RETRIES=20       # Maximum poll attempts
HEALTH_INTERVAL=3       # Seconds between each poll

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK]    $*"; }
warn()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" >&2; }
die()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
BUILD_FLAG=false
ENV_FILE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD_FLAG=true
      shift
      ;;
    --env-file)
      [[ -z "${2:-}" ]] && die "--env-file requires a path argument."
      ENV_FILE_OVERRIDE="$2"
      shift 2
      ;;
    *)
      die "Unknown argument: '${1}'. Usage: $0 [--build] [--env-file <path>]"
      ;;
  esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1        || die "docker is not installed or not in PATH."
docker info >/dev/null 2>&1              || die "Docker daemon is not running."
docker compose version >/dev/null 2>&1  || die "docker compose (v2) plugin is not available."
command -v curl >/dev/null 2>&1         || die "curl is required for the health poll. Please install it."

# ── Resolve .env file ─────────────────────────────────────────────────────────
if [[ -n "${ENV_FILE_OVERRIDE}" ]]; then
  [[ -f "${ENV_FILE_OVERRIDE}" ]] || die "Specified --env-file '${ENV_FILE_OVERRIDE}' does not exist."
  ENV_FILE="${ENV_FILE_OVERRIDE}"
elif [[ -f "${PROJECT_ROOT}/.env" ]]; then
  ENV_FILE="${PROJECT_ROOT}/.env"
else
  warn ".env file not found. Falling back to .env.example (not suitable for production)."
  [[ -f "${PROJECT_ROOT}/.env.example" ]] || die "Neither .env nor .env.example found in ${PROJECT_ROOT}."
  ENV_FILE="${PROJECT_ROOT}/.env.example"
fi

log "Using env file: ${ENV_FILE}"

# ── Optional rebuild ──────────────────────────────────────────────────────────
if [[ "${BUILD_FLAG}" == true ]]; then
  log "Rebuilding images before start (--build flag set)..."
  "${SCRIPT_DIR}/build.sh"
fi

# ── Bring up services ─────────────────────────────────────────────────────────
log "========================================================"
log " Logistics Validation API — Starting Environment"
log "========================================================"

cd "${PROJECT_ROOT}"
docker compose \
  --project-name "${COMPOSE_PROJECT}" \
  --env-file "${ENV_FILE}" \
  up --detach --remove-orphans

log "Containers started. Waiting for the stack to be healthy..."

# ── Health poll ───────────────────────────────────────────────────────────────
# Poll Nginx → FastAPI health endpoint. This confirms both layers are up,
# not just that the container processes started.
attempt=0
until curl --silent --fail --max-time 2 "${HEALTH_URL}" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [[ ${attempt} -ge ${HEALTH_RETRIES} ]]; then
    die "Health endpoint did not respond after $((HEALTH_RETRIES * HEALTH_INTERVAL))s. " \
        "Check logs with: docker compose -p ${COMPOSE_PROJECT} logs --tail=50"
  fi
  log "  Attempt ${attempt}/${HEALTH_RETRIES} — not ready yet, waiting ${HEALTH_INTERVAL}s..."
  sleep "${HEALTH_INTERVAL}"
done

# ── Ready summary ─────────────────────────────────────────────────────────────
success "========================================================"
success " Stack is UP and healthy!"
success "========================================================"
success "  API (via Nginx) : ${HEALTH_URL}"
success "  Swagger UI       : http://localhost/docs"
success ""
success "  Useful commands:"
success "    Logs  → docker compose -p ${COMPOSE_PROJECT} logs -f"
success "    Stop  → ./scripts/stop.sh"
success "    Check → ./scripts/healthcheck.sh"
