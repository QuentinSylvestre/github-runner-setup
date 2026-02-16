#!/usr/bin/env bash
# Setup script for GitHub Actions self-hosted runner on Ubuntu 24.04 LTS.
# Installs all dependencies required by CI jobs and registers the runner.
#
# Usage:
#   ./scripts/runner/setup-runner.sh \
#     --repo OWNER/REPO \
#     --token REGISTRATION_TOKEN \
#     --labels nuc \
#     --name my-nuc-runner
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
RUNNER_DIR="/opt/actions-runner"
RUNNER_USER="runner"

usage() {
  cat <<EOF
Usage: $0 --repo OWNER/REPO --token TOKEN [--labels LABEL1,LABEL2] [--name NAME]
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

# --- Install GitHub Actions runner ---
echo "=== Installing GitHub Actions runner ==="
RUNNER_VERSION=$(
  curl -fsSL -H "Accept: application/vnd.github+json" https://api.github.com/repos/actions/runner/releases/latest \
    | jq -r '.tag_name' \
    | sed 's/^v//'
)
if [[ -z "$RUNNER_VERSION" || "$RUNNER_VERSION" == "null" ]]; then
  die "Failed to resolve latest actions/runner version from GitHub API"
fi
RUNNER_TARBALL="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TARBALL}"
RUNNER_SHA_FILE="${RUNNER_TARBALL}.sha256"
RUNNER_SHA_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_SHA_FILE}"
RUNNER_LOG_DIR="${RUNNER_DIR}/logs"

sudo install -d -m 0750 -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_DIR"
sudo install -d -m 0750 -o "$RUNNER_USER" -g "$RUNNER_USER" "$RUNNER_LOG_DIR"

sudo -u "$RUNNER_USER" env \
  REPO="$REPO" \
  TOKEN="$TOKEN" \
  LABELS="$LABELS" \
  RUNNER_NAME="$RUNNER_NAME" \
  RUNNER_DIR="$RUNNER_DIR" \
  RUNNER_TARBALL="$RUNNER_TARBALL" \
  RUNNER_URL="$RUNNER_URL" \
  RUNNER_SHA_FILE="$RUNNER_SHA_FILE" \
  RUNNER_SHA_URL="$RUNNER_SHA_URL" \
  bash <<'RUNNER_INSTALL'
set -euo pipefail

cd "$RUNNER_DIR"
curl -fsSL -o "$RUNNER_TARBALL" "$RUNNER_URL"
curl -fsSL -o "$RUNNER_SHA_FILE" "$RUNNER_SHA_URL"

# GitHub sometimes publishes checksum files as "<sha>" only. Normalize to
# "sha  filename" before running sha256sum -c.
if ! grep -q "$RUNNER_TARBALL" "$RUNNER_SHA_FILE"; then
  expected_sha="$(awk 'NF {print $1; exit}' "$RUNNER_SHA_FILE")"
  if [[ -z "$expected_sha" ]]; then
    echo "Unable to parse SHA256 from $RUNNER_SHA_FILE" >&2
    exit 1
  fi
  printf '%s  %s\n' "$expected_sha" "$RUNNER_TARBALL" > "$RUNNER_SHA_FILE"
fi

sha256sum -c "$RUNNER_SHA_FILE"
tar xz -f "$RUNNER_TARBALL"
rm -f "$RUNNER_TARBALL" "$RUNNER_SHA_FILE"

if [[ -n "$LABELS" ]]; then
  ./config.sh --url "https://github.com/$REPO" --token "$TOKEN" --name "$RUNNER_NAME" --labels "$LABELS" --unattended --replace
else
  ./config.sh --url "https://github.com/$REPO" --token "$TOKEN" --name "$RUNNER_NAME" --unattended --replace
fi
RUNNER_INSTALL

# --- Register as systemd service ---
echo "=== Registering systemd service ==="
cd "$RUNNER_DIR"
sudo ./svc.sh install "$RUNNER_USER"
sudo ./svc.sh start

SERVICE_NAME="actions.runner.${REPO//\//-}.${RUNNER_NAME}.service"
if sudo systemctl show "$SERVICE_NAME" --property=Id >/dev/null 2>&1; then
  echo "=== Applying systemd hardening ==="
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
else
  echo "WARNING: Runner systemd service ${SERVICE_NAME} not found. Skipping hardening drop-in."
fi

echo "=== Setting up maintenance cron jobs ==="
DOCKER_CLEANUP_CRON="0 3 * * 0 docker system prune -af --filter \"until=168h\" >> ${RUNNER_LOG_DIR}/docker-cleanup.log 2>&1 # runner-docker-cleanup"
WORKSPACE_CLEANUP_CRON="0 4 1 * * find ${RUNNER_DIR}/_work -maxdepth 2 -name \"_temp\" -type d -mtime +30 -exec rm -rf {} + >> ${RUNNER_LOG_DIR}/workspace-cleanup.log 2>&1 # runner-workspace-cleanup"
# Docker cleanup: prune unused images weekly (guard prevents duplicates on re-run)
if ! sudo -u "$RUNNER_USER" crontab -l 2>/dev/null | grep -q 'runner-docker-cleanup'; then
  sudo -u "$RUNNER_USER" bash -c "(crontab -l 2>/dev/null; echo '${DOCKER_CLEANUP_CRON}') | crontab -"
fi
# Runner workspace cleanup: remove old _work directories monthly
if ! sudo -u "$RUNNER_USER" crontab -l 2>/dev/null | grep -q 'runner-workspace-cleanup'; then
  sudo -u "$RUNNER_USER" bash -c "(crontab -l 2>/dev/null; echo '${WORKSPACE_CLEANUP_CRON}') | crontab -"
fi

echo ""
echo "=== Setup complete ==="
if [[ -n "$LABELS" ]]; then
  echo "Runner '${RUNNER_NAME}' registered for ${REPO} with labels: self-hosted,${LABELS}"
else
  echo "Runner '${RUNNER_NAME}' registered for ${REPO} with labels: self-hosted"
fi
echo ""
echo "Runner logs directory: ${RUNNER_LOG_DIR}"
echo ""
echo "Next steps:"
if [[ -n "$LABELS" ]]; then
  echo "  1. Set the GitHub repo variable RUNNER_LABELS to: [\"self-hosted\", \"${LABELS}\"]"
else
  echo "  1. Set the GitHub repo variable RUNNER_LABELS to: [\"self-hosted\"]"
fi
echo "     Go to: https://github.com/${REPO}/settings/variables/actions"
echo "  2. Push a commit or trigger a workflow to verify the runner picks up jobs"
echo "  3. Monitor: sudo journalctl -u ${SERVICE_NAME} -f"
