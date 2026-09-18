#!/usr/bin/env bash
# Update CI dependencies on an existing self-hosted runner.
#
# Re-runs the same dependency installation steps from setup-runner.sh
# without touching the runner registration, systemd services, or cron jobs.
# Safe to run repeatedly (idempotent).
#
# Usage:
#   sudo ./update-deps.sh                   # update and restart runners
#   sudo ./update-deps.sh --no-restart      # update only, skip runner restart
#
# Prerequisites:
#   - Ubuntu 24.04 LTS with a runner already installed via setup-runner.sh
#   - sudo access
set -euo pipefail

NO_RESTART=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --no-restart)
      NO_RESTART=true
      shift
      ;;
    *)
      echo "Usage: $0 [--no-restart]" >&2
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "=== Updating system dependencies ==="
apt-get update
apt-get install -y \
  curl wget git jq unzip software-properties-common \
  build-essential libssl-dev libffi-dev \
  ca-certificates gnupg lsb-release unattended-upgrades
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

# --- Python 3.13 ---
# Installed alongside the OS's own python3, never made the system default.
# update-alternatives --install /usr/bin/python3 ... used to repoint the
# system python3 at 3.13, which broke apt's own tooling: apt_pkg (needed by
# command-not-found's cnf-update-db hook, invoked on every `apt-get update`)
# is a compiled extension tied to the specific python3 build Ubuntu ships
# (3.12 on noble), not whatever python3 happens to point to. Once redirected,
# every subsequent apt-get update failed with
# "ModuleNotFoundError: No module named 'apt_pkg'" and a nonzero exit code,
# which aborted this script (set -euo pipefail) on every future run.
#
# CI doesn't need python3.13 to be the system default anyway: every workflow
# job provisions its own Python 3.13 via actions/setup-python, which
# prepends its managed install to PATH regardless of the system default.
# scripts/dev/setup_test_calendar.py-style callers that need 3.13
# specifically should invoke `python3.13` directly.
echo "=== Installing Python 3.13 ==="
if ! python3.13 --version >/dev/null 2>&1; then
  add-apt-repository -y ppa:deadsnakes/ppa
  apt-get update
  apt-get install -y python3.13 python3.13-venv python3.13-dev
else
  echo "Python 3.13 already installed"
fi
apt-get install -y python3-pip python3-venv python3-dev

# --- Node.js 22 ---
echo "=== Updating Node.js 22 ==="
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# --- Playwright Chromium dependencies ---
echo "=== Updating Playwright Chromium system dependencies ==="
apt-get install -y \
  libasound2t64 \
  libatk1.0-0t64 \
  libatk-bridge2.0-0t64 \
  libatspi2.0-0t64 \
  libcups2t64 \
  libdbus-1-3 \
  libdrm2 \
  libgbm1 \
  libgtk-3-0t64 \
  libnspr4 \
  libnss3 \
  libpango-1.0-0 \
  libxcomposite1 \
  libxdamage1 \
  libxfixes3 \
  libxkbcommon0 \
  libxrandr2 \
  libxshmfence1 \
  fonts-liberation

# --- Java 21 (Temurin, for Firestore emulator) ---
echo "=== Updating Java 21 (Temurin) ==="
if [[ ! -f /etc/apt/sources.list.d/adoptium.list ]]; then
  wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | \
    gpg --dearmor --yes -o /usr/share/keyrings/adoptium.gpg
  echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/adoptium.list
  apt-get update
fi
apt-get install -y temurin-21-jdk

# --- Docker ---
echo "=== Updating Docker ==="
if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list
  apt-get update
fi
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# --- Terraform ---
echo "=== Updating Terraform ==="
if [[ ! -f /etc/apt/sources.list.d/hashicorp.list ]]; then
  wget -qO - https://apt.releases.hashicorp.com/gpg | \
    gpg --dearmor --yes -o /usr/share/keyrings/hashicorp.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/hashicorp.list
  apt-get update
fi
apt-get install -y terraform

# --- Google Cloud SDK ---
echo "=== Updating Google Cloud SDK ==="
if [[ ! -f /etc/apt/sources.list.d/google-cloud-sdk.list ]]; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
    tee /etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update
fi
apt-get install -y google-cloud-sdk google-cloud-cli-firestore-emulator

# --- Restart runner services ---
if [[ "$NO_RESTART" == "false" ]]; then
  echo ""
  echo "=== Restarting runner services ==="
  SERVICES=$(systemctl list-units --type=service --all --no-legend "actions.runner.*" | awk '{print $1}')
  if [[ -z "$SERVICES" ]]; then
    echo "No actions.runner.* services found. Skipping restart."
  else
    while IFS= read -r svc; do
      echo "Restarting ${svc}..."
      systemctl restart "$svc"
      sleep 3
      if systemctl is-active --quiet "$svc"; then
        echo "  OK: ${svc} restarted successfully."
      else
        echo "  WARNING: ${svc} did not stay active after restart." >&2
        systemctl status "$svc" --no-pager --lines=5 >&2
      fi
    done <<< "$SERVICES"
  fi
else
  echo ""
  echo "Skipping runner restart (--no-restart). Restart manually when ready:"
  echo "  ./restart-runner.sh"
fi

echo ""
echo "=== Dependency update complete ==="
