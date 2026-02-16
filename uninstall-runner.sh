#!/usr/bin/env bash
# Uninstall GitHub Actions self-hosted runner(s) and clean up.
# Auto-detects all runner instances under /opt/actions-runner*.
#
# Usage: ./scripts/runner/uninstall-runner.sh --token REMOVAL_TOKEN
set -euo pipefail

TOKEN=""
RUNNER_BASE_DIR="/opt/actions-runner"
RUNNER_USER="runner"

usage() {
  cat <<EOF
Usage: $0 --token REMOVAL_TOKEN
Get a removal token from: GitHub repo Settings > Actions > Runners > ... > Remove
EOF
}

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
    --token)
      require_argument_value "$1" "${2:-}"
      TOKEN="$2"
      shift 2
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [[ -z "$TOKEN" ]]; then
  usage
  exit 1
fi

# Find all runner directories: /opt/actions-runner and /opt/actions-runner-*
RUNNER_DIRS=()
if [[ -d "$RUNNER_BASE_DIR" && -f "${RUNNER_BASE_DIR}/config.sh" ]]; then
  RUNNER_DIRS+=("$RUNNER_BASE_DIR")
fi
for d in "${RUNNER_BASE_DIR}"-*/; do
  if [[ -d "$d" && -f "${d}config.sh" ]]; then
    RUNNER_DIRS+=("${d%/}")
  fi
done

if [[ ${#RUNNER_DIRS[@]} -eq 0 ]]; then
  die "No runner directories found matching ${RUNNER_BASE_DIR}*"
fi

echo "Found ${#RUNNER_DIRS[@]} runner instance(s) to uninstall:"
for d in "${RUNNER_DIRS[@]}"; do
  echo "  - $d"
done
echo ""

FAILED=0

for RUNNER_DIR in "${RUNNER_DIRS[@]}"; do
  echo "=== Uninstalling runner in ${RUNNER_DIR} ==="

  cd "$RUNNER_DIR"
  sudo ./svc.sh stop || true
  sudo ./svc.sh uninstall || true

  echo "--- Removing runner registration ---"
  sudo -u "$RUNNER_USER" env RUNNER_DIR="$RUNNER_DIR" TOKEN="$TOKEN" bash <<'RUNNER_UNINSTALL'
set -euo pipefail
cd "$RUNNER_DIR"
./config.sh remove --token "$TOKEN"
RUNNER_UNINSTALL

  if [[ $? -ne 0 ]]; then
    echo "WARNING: Failed to unregister runner in ${RUNNER_DIR}" >&2
    FAILED=$((FAILED + 1))
  fi
done

# Clean up workspace cleanup cron (it references runner directories)
if sudo -u "$RUNNER_USER" crontab -l 2>/dev/null | grep -q 'runner-workspace-cleanup'; then
  echo "=== Removing workspace cleanup cron job ==="
  sudo -u "$RUNNER_USER" bash -c "(crontab -l 2>/dev/null | grep -v 'runner-workspace-cleanup') | crontab -"
fi
if sudo -u "$RUNNER_USER" crontab -l 2>/dev/null | grep -q 'runner-docker-cleanup'; then
  echo "=== Removing docker cleanup cron job ==="
  sudo -u "$RUNNER_USER" bash -c "(crontab -l 2>/dev/null | grep -v 'runner-docker-cleanup') | crontab -"
fi

echo ""
echo "=== Cleanup complete ==="
if [[ "$FAILED" -gt 0 ]]; then
  echo "WARNING: ${FAILED} runner(s) failed to unregister." >&2
fi
echo "Unregistered ${#RUNNER_DIRS[@]} runner(s). You can now delete the directories if desired:"
for d in "${RUNNER_DIRS[@]}"; do
  echo "  sudo rm -rf $d"
done
echo ""
echo "Remember to clear the RUNNER_LABELS variable in GitHub repo settings."
