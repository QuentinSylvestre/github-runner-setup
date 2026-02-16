#!/usr/bin/env bash
# Restart GitHub Actions self-hosted runner service(s) and verify they come back.
#
# Usage:
#   ./scripts/runner/restart-runner.sh                              # restart all detected runners
#   ./scripts/runner/restart-runner.sh --repo OWNER/REPO --name R   # restart a specific runner
set -euo pipefail

REPO=""
RUNNER_NAME=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_argument_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die "Missing value for ${option}"
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)
      require_argument_value "$1" "${2:-}"
      REPO="$2"
      shift 2
      ;;
    --name)
      require_argument_value "$1" "${2:-}"
      RUNNER_NAME="$2"
      shift 2
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# Build service list: specific service or auto-detect all
SERVICES=()

if [[ -n "$REPO" && -n "$RUNNER_NAME" ]]; then
  SERVICES+=("actions.runner.${REPO//\//-}.${RUNNER_NAME}.service")
else
  MATCHES=$(systemctl list-units --type=service --all --no-legend "actions.runner.*" | awk '{print $1}')
  if [[ -z "$MATCHES" ]]; then
    die "No actions.runner.* service found. Use --repo and --name to specify explicitly."
  fi
  while IFS= read -r svc; do
    SERVICES+=("$svc")
  done <<< "$MATCHES"
  echo "Auto-detected ${#SERVICES[@]} runner service(s)."
fi

FAILED=0

for SERVICE_NAME in "${SERVICES[@]}"; do
  if ! systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "WARNING: Service not found: ${SERVICE_NAME}" >&2
    FAILED=$((FAILED + 1))
    continue
  fi

  echo "=== Restarting ${SERVICE_NAME} ==="
  sudo systemctl restart "$SERVICE_NAME"

  # Wait briefly and verify the service stayed up
  sleep 3

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "OK: ${SERVICE_NAME} restarted successfully."
  else
    echo "FAILED: ${SERVICE_NAME} did not stay active after restart." >&2
    systemctl status "$SERVICE_NAME" --no-pager --lines=10 >&2
    FAILED=$((FAILED + 1))
  fi
done

if [[ "$FAILED" -gt 0 ]]; then
  die "${FAILED} runner(s) failed to restart."
fi

echo ""
echo "All ${#SERVICES[@]} runner(s) restarted successfully."
