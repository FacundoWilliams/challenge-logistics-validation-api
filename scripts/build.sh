#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  scripts/build.sh
#  Build the Docker image for the Logistics Validation API.
#
#  Usage:
#    ./scripts/build.sh [--no-cache]
#
#  Tags produced:
#    logistics-api:local   → always applied (stable local dev tag)
#    logistics-api:<sha>   → short git SHA for traceability
#
#  Options:
#    --no-cache  Pass --no-cache to docker build (useful for clean CI builds)
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail  # -e: exit on error | -u: error on unset vars | -o pipefail: pipe errors propagate

# ── Configuration ─────────────────────────────────────────────────────────────
IMAGE_NAME="logistics-api"
LOCAL_TAG="${IMAGE_NAME}:local"

# Derive a short git SHA for image traceability; fall back gracefully if git
# is unavailable (e.g. running outside a git repository).
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
SHA_TAG="${IMAGE_NAME}:${GIT_SHA}"

# Resolve the directory where this script lives so it can be called from
# any working directory (e.g. `make build` from the project root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" >&2; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
NO_CACHE_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --no-cache) NO_CACHE_FLAG="--no-cache" ;;
    *) die "Unknown argument: '${arg}'. Usage: $0 [--no-cache]" ;;
  esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH."
docker info >/dev/null 2>&1       || die "Docker daemon is not running."

# ── Build ─────────────────────────────────────────────────────────────────────
log "========================================================"
log " Logistics Validation API — Docker Build"
log "========================================================"
log "Project root : ${PROJECT_ROOT}"
log "Image        : ${LOCAL_TAG}"
log "Git SHA tag  : ${SHA_TAG}"
[[ -n "${NO_CACHE_FLAG}" ]] && warn "--no-cache flag is set. This will be a full rebuild."

log "Building image (target: runner stage)..."
docker build \
  ${NO_CACHE_FLAG} \
  --target runner \
  --tag "${LOCAL_TAG}" \
  --tag "${SHA_TAG}" \
  --label "build.git-sha=${GIT_SHA}" \
  --label "build.timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "${PROJECT_ROOT}"

# ── Post-build summary ────────────────────────────────────────────────────────
log "Build completed successfully."
log "Tags applied:"
log "  • ${LOCAL_TAG}"
log "  • ${SHA_TAG}"

IMAGE_SIZE=$(docker image inspect "${LOCAL_TAG}" --format '{{.Size}}' | awk '{printf "%.1f MB", $1/1024/1024}')
log "Final image size: ${IMAGE_SIZE}"
log ""
log "Next step → run: ./scripts/start.sh"
