#!/usr/bin/env bash
# Setup script for GitHub Actions self-hosted runner on Ubuntu 24.04 LTS.
# Installs all dependencies required by CI jobs and registers the runner(s).
#
# Usage:
#   # Single runner (default)
#   ./scripts/runner/setup-runner.sh \
#     --repo OWNER/REPO \
#     --token REGISTRATION_TOKEN \
#     --labels nuc \
#     --name my-nuc-runner
#
#   # Multiple runners for parallel CI jobs
#   ./scripts/runner/setup-runner.sh \
#     --repo OWNER/REPO \
#     --token REGISTRATION_TOKEN \
#     --labels nuc \
#     --name my-nuc \
#     --count 3
#
# Prerequisites:
#   - Ubuntu 24.04 LTS (fresh install or VM)
#   - sudo access
#   - Outbound HTTPS to github.com, *.actions.githubusercontent.com,
#     and runtime registries (pypi.org, registry.npmjs.org, *.docker.io)
#
# Note: Registration tokens expire after 1 hour. Generate the token
# immediately before running this script.
set -euo pipefail
umask 027

# --- Parse arguments ---
REPO=""
TOKEN=""
LABELS=""
RUNNER_NAME="$(hostname)"
RUNNER_BASE_DIR="/opt/actions-runner"
RUNNER_USER="runner"
RUNNER_COUNT=1

usage() {
  cat <<EOF
Usage: $0 --repo OWNER/REPO --token TOKEN [--labels LABEL1,LABEL2] [--name NAME] [--count N]
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
    --repo)
      require_argument_value "$1" "${2:-}"
      REPO="$2"
      shift 2
      ;;
    --token)
      require_argument_value "$1" "${2:-}"
      TOKEN="$2"
      shift 2
      ;;
    --labels)
      require_argument_value "$1" "${2:-}"
      LABELS="$2"
      shift 2
      ;;
    --name)
      require_argument_value "$1" "${2:-}"
      RUNNER_NAME="$2"
      shift 2
      ;;
    --count)
      require_argument_value "$1" "${2:-}"
      RUNNER_COUNT="$2"
      shift 2
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [[ -z "$REPO" || -z "$TOKEN" ]]; then
  usage
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  die "sudo is required"
fi

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  die "Invalid --repo format. Expected OWNER/REPO"
fi

if [[ ! "$RUNNER_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die "Invalid --name. Allowed characters: letters, digits, ., _, -"
fi

if [[ -n "$LABELS" && ! "$LABELS" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
  die "Invalid --labels. Use comma-separated labels with characters: letters, digits, ., _, -"
fi

if [[ ! "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  die "Invalid --count. Must be a positive integer."
fi

# --- Helper: derive runner name and directory for instance i ---
# count=1: /opt/actions-runner, original name (backward compatible)
# count>1: /opt/actions-runner-{i}, {name}-{i}
instance_name() {
  local i="$1"
  if [[ "$RUNNER_COUNT" -eq 1 ]]; then
    echo "$RUNNER_NAME"
  else
    echo "${RUNNER_NAME}-${i}"
  fi
}

instance_dir() {
  local i="$1"
  if [[ "$RUNNER_COUNT" -eq 1 ]]; then
    echo "$RUNNER_BASE_DIR"
  else
    echo "${RUNNER_BASE_DIR}-${i}"
  fi
}

echo "=== Installing system dependencies ==="
sudo apt-get update
sudo apt-get install -y \
  curl wget git jq unzip software-properties-common \
  build-essential libssl-dev libffi-dev \
  ca-certificates gnupg lsb-release unattended-upgrades
sudo systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

# --- Python 3.12 ---
# Ubuntu 24.04 ships Python 3.12 by default; only add deadsnakes if missing
echo "=== Installing Python 3.12 ==="
if python3 --version 2>/dev/null | grep -q "3.12"; then
  echo "Python 3.12 already installed (system default)"
else
  sudo add-apt-repository -y ppa:deadsnakes/ppa
  sudo apt-get update
  sudo apt-get install -y python3.12 python3.12-venv python3.12-dev
  sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1
fi
sudo apt-get install -y python3-pip python3-venv python3-dev

# --- Node.js 22 ---
echo "=== Installing Node.js 22 ==="
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# --- Java 21 (Temurin, for Firestore emulator) ---
echo "=== Installing Java 21 (Temurin) ==="
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | \
  sudo gpg --dearmor --yes -o /usr/share/keyrings/adoptium.gpg
echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/adoptium.list
sudo apt-get update
sudo apt-get install -y temurin-21-jdk

# --- Docker ---
echo "=== Installing Docker ==="
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin

# --- Terraform 1.9.x ---
echo "=== Installing Terraform ==="
wget -qO - https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y terraform

# --- Google Cloud SDK (for Firestore emulator) ---
echo "=== Installing Google Cloud SDK ==="
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
  sudo gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
  sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
sudo apt-get update
sudo apt-get install -y google-cloud-sdk google-cloud-cli-firestore-emulator

# --- Create runner user ---
# Docker is installed before the runner user is created and before the systemd
# service starts, so the docker group membership is effective when the service
# launches.
echo "=== Creating runner user ==="
if ! id "$RUNNER_USER" &>/dev/null; then
  sudo useradd -m -s /bin/bash "$RUNNER_USER"
fi
sudo usermod -aG docker "$RUNNER_USER"

# --- Download GitHub Actions runner (once) ---
echo "=== Downloading GitHub Actions runner ==="
RELEASE_JSON=$(curl -fsSL -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/actions/runner/releases/latest)

RUNNER_VERSION=$(echo "$RELEASE_JSON" | jq -r '.tag_name' | sed 's/^v//')
if [[ -z "$RUNNER_VERSION" || "$RUNNER_VERSION" == "null" ]]; then
  die "Failed to resolve latest actions/runner version from GitHub API"
fi

RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

# Extract download URL and SHA256 from the release asset metadata
RUNNER_URL=$(echo "$RELEASE_JSON" | jq -r --arg name "$RUNNER_TARBALL" \
  '.assets[] | select(.name == $name) | .browser_download_url')
RUNNER_SHA=$(echo "$RELEASE_JSON" | jq -r --arg name "$RUNNER_TARBALL" \
  '.assets[] | select(.name == $name) | .digest' | sed 's/^sha256://')

if [[ -z "$RUNNER_URL" || "$RUNNER_URL" == "null" ]]; then
  die "Asset ${RUNNER_TARBALL} not found in release v${RUNNER_VERSION}"
fi
if [[ -z "$RUNNER_SHA" || "$RUNNER_SHA" == "null" ]]; then
  die "SHA256 digest not found for ${RUNNER_TARBALL}"
fi

# Download and verify once in /tmp
DOWNLOAD_DIR=$(mktemp -d)
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

echo "Downloading ${RUNNER_TARBALL} (v${RUNNER_VERSION})..."
curl -fsSL -o "${DOWNLOAD_DIR}/${RUNNER_TARBALL}" "$RUNNER_URL"

cd "$DOWNLOAD_DIR"
printf '%s  %s\n' "$RUNNER_SHA" "$RUNNER_TARBALL" | sha256sum -c -

# --- Install runner instance(s) ---
INSTALLED_SERVICES=()

for i in $(seq 1 "$RUNNER_COUNT"); do
  INST_NAME=$(instance_name "$i")
  INST_DIR=$(instance_dir "$i")
  INST_LOG_DIR="${INST_DIR}/logs"

  if [[ "$RUNNER_COUNT" -gt 1 ]]; then
    echo ""
    echo "=== Installing runner ${i}/${RUNNER_COUNT}: ${INST_NAME} ==="
  else
    echo ""
    echo "=== Installing GitHub Actions runner ==="
  fi

  sudo install -d -m 0750 -o "$RUNNER_USER" -g "$RUNNER_USER" "$INST_DIR"
  sudo install -d -m 0750 -o "$RUNNER_USER" -g "$RUNNER_USER" "$INST_LOG_DIR"

  # Extract tarball and configure as the runner user
  sudo -u "$RUNNER_USER" env \
    REPO="$REPO" \
    TOKEN="$TOKEN" \
    LABELS="$LABELS" \
    INST_NAME="$INST_NAME" \
    INST_DIR="$INST_DIR" \
    RUNNER_TARBALL="$RUNNER_TARBALL" \
    DOWNLOAD_DIR="$DOWNLOAD_DIR" \
    bash <<'RUNNER_INSTALL'
set -euo pipefail

cd "$INST_DIR"
tar xz -f "${DOWNLOAD_DIR}/${RUNNER_TARBALL}"

if [[ -n "$LABELS" ]]; then
  ./config.sh --url "https://github.com/$REPO" --token "$TOKEN" --name "$INST_NAME" --labels "$LABELS" --unattended --replace
else
  ./config.sh --url "https://github.com/$REPO" --token "$TOKEN" --name "$INST_NAME" --unattended --replace
fi
RUNNER_INSTALL

  # Register as systemd service
  echo "--- Registering systemd service for ${INST_NAME} ---"
  cd "$INST_DIR"
  sudo ./svc.sh install "$RUNNER_USER"
  sudo ./svc.sh start

  SERVICE_NAME="actions.runner.${REPO//\//-}.${INST_NAME}.service"
  INSTALLED_SERVICES+=("$SERVICE_NAME")

  if sudo systemctl show "$SERVICE_NAME" --property=Id >/dev/null 2>&1; then
    echo "--- Applying systemd hardening for ${INST_NAME} ---"
    sudo install -d -m 0755 "/etc/systemd/system/${SERVICE_NAME}.d"
    cat <<EOF | sudo tee "/etc/systemd/system/${SERVICE_NAME}.d/hardening.conf" >/dev/null
[Service]
NoNewPrivileges=true
PrivateTmp=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictSUIDSGID=true
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart "$SERVICE_NAME"

    # Verify the service stayed active after hardening restart
    sleep 3
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
      echo "WARNING: ${SERVICE_NAME} failed to stay active after hardening. Removing drop-in and restarting." >&2
      sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.d/hardening.conf"
      sudo systemctl daemon-reload
      sudo systemctl restart "$SERVICE_NAME"
    fi
  else
    echo "WARNING: Runner systemd service ${SERVICE_NAME} not found. Skipping hardening drop-in."
  fi
done

# --- Maintenance cron jobs (once per runner user, not per instance) ---
echo ""
echo "=== Setting up maintenance cron jobs ==="
# Use the first instance's log dir for cron output
FIRST_LOG_DIR="$(instance_dir 1)/logs"
DOCKER_CLEANUP_CRON="0 3 * * 0 docker system prune -af --filter \"until=168h\" >> ${FIRST_LOG_DIR}/docker-cleanup.log 2>&1 # runner-docker-cleanup"
# Docker cleanup: prune unused images weekly (guard prevents duplicates on re-run)
if ! sudo -u "$RUNNER_USER" crontab -l 2>/dev/null | grep -q 'runner-docker-cleanup'; then
  sudo -u "$RUNNER_USER" bash -c "(crontab -l 2>/dev/null; echo '${DOCKER_CLEANUP_CRON}') | crontab -"
fi
# Build workspace cleanup cron covering all instance _work directories
WORKSPACE_FIND_PATHS=""
for i in $(seq 1 "$RUNNER_COUNT"); do
  WORKSPACE_FIND_PATHS+=" $(instance_dir "$i")/_work"
done
WORKSPACE_CLEANUP_CRON="0 4 1 * * find${WORKSPACE_FIND_PATHS} -maxdepth 2 -name \"_temp\" -type d -mtime +30 -exec rm -rf {} + >> ${FIRST_LOG_DIR}/workspace-cleanup.log 2>&1 # runner-workspace-cleanup"
# Runner workspace cleanup: remove old _work directories monthly
# Remove existing entry first (paths may have changed on re-run)
if sudo -u "$RUNNER_USER" crontab -l 2>/dev/null | grep -q 'runner-workspace-cleanup'; then
  sudo -u "$RUNNER_USER" bash -c "(crontab -l 2>/dev/null | grep -v 'runner-workspace-cleanup') | crontab -"
fi
sudo -u "$RUNNER_USER" bash -c "(crontab -l 2>/dev/null; echo '${WORKSPACE_CLEANUP_CRON}') | crontab -"

echo ""
echo "=== Setup complete ==="
if [[ "$RUNNER_COUNT" -gt 1 ]]; then
  echo "${RUNNER_COUNT} runners registered for ${REPO}:"
  for i in $(seq 1 "$RUNNER_COUNT"); do
    echo "  - $(instance_name "$i") ($(instance_dir "$i"))"
  done
else
  echo "Runner '${RUNNER_NAME}' registered for ${REPO}."
fi
if [[ -n "$LABELS" ]]; then
  echo "Labels: self-hosted,${LABELS}"
else
  echo "Labels: self-hosted"
fi
echo ""
echo "Next steps:"
if [[ -n "$LABELS" ]]; then
  echo "  1. Set the GitHub repo variable RUNNER_LABELS to: [\"self-hosted\", \"${LABELS}\"]"
else
  echo "  1. Set the GitHub repo variable RUNNER_LABELS to: [\"self-hosted\"]"
fi
echo "     Go to: https://github.com/${REPO}/settings/variables/actions"
echo "  2. Push a commit or trigger a workflow to verify the runner(s) pick up jobs"
echo "  3. Monitor:"
for svc in "${INSTALLED_SERVICES[@]}"; do
  echo "     sudo journalctl -u ${svc} -f"
done
