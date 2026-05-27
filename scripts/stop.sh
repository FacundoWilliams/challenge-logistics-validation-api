#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  scripts/stop.sh
#  Tear down the Logistics Validation API environment safely.
#
#  Usage:
#    ./scripts/stop.sh [--volumes] [--rmi]
#
#  Options:
#    --volumes   Also remove named Docker volumes (data loss — use with care).
#    --rmi       Also remove the built images (forces a full rebuild next time).
#
#  What this script does:
#    1. Stops all running containers in the Compose project.
#    2. Removes containers and the internal Docker network.
#    3. Optionally removes volumes and images.
#    4. Prints a final status confirming cleanup.
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
COMPOSE_PROJECT="logistics"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
success() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK]    $*"; }
warn()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" >&2; }
die()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
REMOVE_VOLUMES=false
REMOVE_IMAGES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volumes) REMOVE_VOLUMES=true; shift ;;
    --rmi)     REMOVE_IMAGES=true;  shift ;;
    *)         die "Unknown argument: '${1}'. Usage: $0 [--volumes] [--rmi]" ;;
  esac
done

# ── Pre-flight ────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1       || die "docker is not installed or not in PATH."
docker compose version >/dev/null 2>&1 || die "docker compose (v2) plugin is not available."

# ── Warnings for destructive flags ───────────────────────────────────────────
if [[ "${REMOVE_VOLUMES}" == true ]]; then
  warn "⚠  --volumes flag set: named Docker volumes will be DELETED."
fi
if [[ "${REMOVE_IMAGES}" == true ]]; then
  warn "⚠  --rmi flag set: built images will be REMOVED (next start requires a full rebuild)."
fi

# ── Build the `docker compose down` argument list ────────────────────────────
DOWN_ARGS=()
[[ "${REMOVE_VOLUMES}" == true ]] && DOWN_ARGS+=("--volumes")
[[ "${REMOVE_IMAGES}"  == true ]] && DOWN_ARGS+=("--rmi" "all")

# ── Teardown ──────────────────────────────────────────────────────────────────
log "========================================================"
log " Logistics Validation API — Stopping Environment"
log "========================================================"

cd "${PROJECT_ROOT}"

# Check if the project has any running containers before attempting to stop.
RUNNING=$(docker compose --project-name "${COMPOSE_PROJECT}" ps --quiet 2>/dev/null | wc -l | tr -d ' ')

if [[ "${RUNNING}" -eq 0 ]]; then
  warn "No running containers found for project '${COMPOSE_PROJECT}'. Nothing to stop."
else
  log "Stopping ${RUNNING} container(s)..."
  docker compose \
    --project-name "${COMPOSE_PROJECT}" \
    down \
    --remove-orphans \
    "${DOWN_ARGS[@]}"
fi

# ── Verify cleanup ────────────────────────────────────────────────────────────
# Confirm no containers from this project are still running.
REMAINING=$(docker compose --project-name "${COMPOSE_PROJECT}" ps --quiet 2>/dev/null | wc -l | tr -d ' ')
if [[ "${REMAINING}" -gt 0 ]]; then
  die "Some containers are still running after teardown. Check manually with: docker ps"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
success "========================================================"
success " Environment stopped and cleaned up successfully."
success "========================================================"
[[ "${REMOVE_VOLUMES}" == true ]] && success "  Volumes : removed"
[[ "${REMOVE_IMAGES}"  == true ]] && success "  Images  : removed"
success ""
success "  To start again: ./scripts/start.sh [--build]"
