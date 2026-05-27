#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  scripts/healthcheck.sh
#  Continuous health monitor for the Logistics Validation API.
#
#  Polls GET http://localhost/health (through Nginx) every 5 seconds and
#  prints a timestamped status line indicating whether the service is UP
#  or DOWN. Tracks consecutive failures so operators can distinguish a
#  brief glitch from a sustained outage.
#
#  Usage:
#    ./scripts/healthcheck.sh [--url <url>] [--interval <seconds>]
#
#  Options:
#    --url <url>          Override the default health endpoint URL.
#                         Default: http://localhost/health
#    --interval <secs>    Poll interval in seconds. Default: 5
#
#  Exit:
#    Ctrl+C to stop. The script traps SIGINT/SIGTERM for a clean exit message.
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
HEALTH_URL="http://localhost/health"
INTERVAL=5

# ── ANSI colours (degrade gracefully in non-TTY environments) ─────────────────
if [[ -t 1 ]]; then
  GREEN="\033[0;32m"
  RED="\033[0;31m"
  YELLOW="\033[0;33m"
  CYAN="\033[0;36m"
  RESET="\033[0m"
else
  # Running in a pipe or CI: disable colour codes to keep logs clean.
  GREEN="" RED="" YELLOW="" CYAN="" RESET=""
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log_up()   { echo -e "[$(timestamp)] ${GREEN}[  UP  ]${RESET} ${HEALTH_URL} responded ${CYAN}${1}${RESET}"; }
log_down() { echo -e "[$(timestamp)] ${RED}[ DOWN ]${RESET} ${HEALTH_URL} — ${1} (consecutive failures: ${2})"; }
log_info() { echo -e "[$(timestamp)] ${YELLOW}[ INFO ]${RESET} $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      [[ -z "${2:-}" ]] && { echo "ERROR: --url requires a value."; exit 1; }
      HEALTH_URL="$2"
      shift 2
      ;;
    --interval)
      [[ -z "${2:-}" ]] && { echo "ERROR: --interval requires a value."; exit 1; }
      [[ "$2" =~ ^[0-9]+$ ]] || { echo "ERROR: --interval must be a positive integer."; exit 1; }
      INTERVAL="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: '${1}'. Usage: $0 [--url <url>] [--interval <seconds>]"
      exit 1
      ;;
  esac
done

# ── Pre-flight ────────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required."; exit 1; }

# ── Graceful shutdown trap ────────────────────────────────────────────────────
_on_exit() {
  echo ""
  log_info "Healthcheck monitor stopped (received signal). Goodbye."
  exit 0
}
trap '_on_exit' SIGINT SIGTERM

# ── State ─────────────────────────────────────────────────────────────────────
consecutive_failures=0

# ── Header ────────────────────────────────────────────────────────────────────
log_info "======================================================"
log_info " Logistics Validation API — Health Monitor"
log_info "======================================================"
log_info "Endpoint : ${HEALTH_URL}"
log_info "Interval : ${INTERVAL}s"
log_info "Press Ctrl+C to stop."
log_info ""

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
  # curl flags:
  #   --silent         → suppress progress meter
  #   --fail           → exit non-zero on HTTP 4xx/5xx
  #   --max-time 3     → timeout after 3s (don't let a hung connection block the loop)
  #   --write-out      → capture the HTTP status code
  #   --output /dev/null → discard the response body
  HTTP_STATUS=$(
    curl --silent \
         --fail \
         --max-time 3 \
         --write-out "%{http_code}" \
         --output /dev/null \
         "${HEALTH_URL}" 2>/dev/null
  ) || HTTP_STATUS="000"  # 000 = connection refused / timeout

  if [[ "${HTTP_STATUS}" == "200" ]]; then
    consecutive_failures=0
    log_up "HTTP ${HTTP_STATUS}"
  else
    consecutive_failures=$((consecutive_failures + 1))

    # Map common status codes / curl errors to human-readable reasons.
    case "${HTTP_STATUS}" in
      000) reason="Connection refused or timed out" ;;
      502) reason="Bad Gateway — upstream (FastAPI) may be down" ;;
      503) reason="Service Unavailable" ;;
      504) reason="Gateway Timeout" ;;
      *)   reason="HTTP ${HTTP_STATUS}" ;;
    esac

    log_down "${reason}" "${consecutive_failures}"
  fi

  sleep "${INTERVAL}"
done
