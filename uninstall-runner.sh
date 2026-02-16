#!/usr/bin/env bash
# Uninstall the GitHub Actions self-hosted runner and clean up.
#
# Usage: ./scripts/runner/uninstall-runner.sh --token REMOVAL_TOKEN
set -euo pipefail

TOKEN=""
RUNNER_DIR="/opt/actions-runner"
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

if [[ ! -d "$RUNNER_DIR" ]]; then
  die "Runner directory does not exist: $RUNNER_DIR"
fi

echo "=== Stopping runner service ==="
cd "$RUNNER_DIR"
sudo ./svc.sh stop || true
sudo ./svc.sh uninstall || true

echo "=== Removing runner registration ==="
sudo -u "$RUNNER_USER" env RUNNER_DIR="$RUNNER_DIR" TOKEN="$TOKEN" bash <<'RUNNER_UNINSTALL'
set -euo pipefail
cd "$RUNNER_DIR"
./config.sh remove --token "$TOKEN"
RUNNER_UNINSTALL

echo "=== Cleanup complete ==="
echo "The runner has been unregistered. You can now delete $RUNNER_DIR if desired."
echo "Remember to clear the RUNNER_LABELS variable in GitHub repo settings."
