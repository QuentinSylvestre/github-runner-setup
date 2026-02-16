# GitHub Actions Self-Hosted Runner Setup

Scripts to provision a self-hosted GitHub Actions runner on Ubuntu 24.04 LTS.
Installs CI dependencies (Python, Node.js, Java, Docker, Terraform, Google Cloud SDK),
registers the runner, and configures systemd services with hardening.

Supports multiple runner instances on a single machine for parallel CI jobs.

## Prerequisites

- Ubuntu 24.04 LTS (VM or bare metal)
- 8 GB+ RAM, 4+ CPU cores, 50 GB+ disk
- Outbound HTTPS access to: `github.com`, `*.actions.githubusercontent.com`,
  `pypi.org`, `files.pythonhosted.org`, `registry.npmjs.org`, `*.docker.io`,
  `packages.cloud.google.com`
- sudo access on the machine

## Quick Start

```bash
git clone https://github.com/QuentinSylvestre/github-runner-setup.git
cd github-runner-setup
```

1. Generate a runner registration token:
   - Go to your repo's **Settings > Actions > Runners > New self-hosted runner**
   - Copy the token (**valid for 1 hour** -- run the setup script immediately)

2. Run the setup script:
   ```bash
   # Single runner
   ./setup-runner.sh \
     --repo OWNER/REPO \
     --token YOUR_TOKEN \
     --labels nuc \
     --name my-runner

   # Multiple runners for parallel CI jobs
   ./setup-runner.sh \
     --repo OWNER/REPO \
     --token YOUR_TOKEN \
     --labels nuc \
     --name my-runner \
     --count 3
   ```

3. Set the `RUNNER_LABELS` variable in your repo (**Settings > Secrets and variables > Actions > Variables**):
   ```json
   ["self-hosted", "nuc"]
   ```

4. Use `RUNNER_LABELS` in your workflow's `runs-on`:
   ```yaml
   jobs:
     build:
       runs-on: ${{ fromJSON(vars.RUNNER_LABELS || '["ubuntu-latest"]') }}
   ```
   Clear the variable to fall back to GitHub-hosted `ubuntu-latest` runners.

5. Push a commit or trigger a workflow to verify.

## Scripts

| Script | Purpose |
|---|---|
| `setup-runner.sh` | Install dependencies, register runner(s), configure systemd |
| `restart-runner.sh` | Restart all (or specific) runner services with health check |
| `uninstall-runner.sh` | Stop, deregister, and clean up all runner instances |

## Multi-Runner Support

With `--count N`, the setup script creates N runner instances that form a pool:

| Count | Directories | Runner names | Parallelism |
|---|---|---|---|
| 1 (default) | `/opt/actions-runner/` | `my-runner` | Sequential |
| 3 | `/opt/actions-runner-{1,2,3}/` | `my-runner-{1,2,3}` | Up to 3 concurrent jobs |

All instances share the same labels. GitHub distributes jobs to whichever runner is idle.
A single registration token works for all instances.

**Sizing guidance**: Each runner is lightweight (~100 MB idle), but the jobs they run
(Docker builds, npm installs, test suites) are resource-intensive. For a 4-core / 8 GB
machine, 2-3 runners is a practical sweet spot.

## VM Creation Checklist

If creating a new VM for the runner:

1. **Hypervisor**: Proxmox, libvirt/virt-manager, VirtualBox, or bare metal
2. **ISO**: Ubuntu Server 24.04 LTS
3. **Resources**: 8 GB RAM, 4 CPU cores, 50 GB disk (thin provisioned)
4. **Install options**: Minimal server, enable OpenSSH server
5. **Network**: Static IP or DHCP reservation for stable connectivity
6. **User**: Create an admin user with sudo access (the setup script creates a
   dedicated `runner` user)
7. After install, SSH in and run the setup script

## Operations

### Check status
```bash
sudo systemctl status "actions.runner.*"
sudo journalctl -u actions.runner.OWNER-REPO.RUNNER_NAME.service -f
```

### Restart
```bash
# Restart all detected runners
./restart-runner.sh

# Restart a specific runner
./restart-runner.sh --repo OWNER/REPO --name my-runner-1
```

### Uninstall
```bash
# Generate a removal token from Settings > Actions > Runners > ... > Remove
./uninstall-runner.sh --token YOUR_REMOVAL_TOKEN
```

### Fallback to GitHub-hosted
Delete or clear the `RUNNER_LABELS` variable. All CI jobs will use `ubuntu-latest`
on the next run.

## What Gets Installed

The setup script installs:

- **Python 3.12** (system default on Ubuntu 24.04, or via deadsnakes PPA)
- **Node.js 22** (via NodeSource)
- **Java 21** (Eclipse Temurin, for Firestore emulator)
- **Docker CE** (with buildx plugin)
- **Terraform** (via HashiCorp APT repo)
- **Google Cloud SDK** (with Firestore emulator)
- **unattended-upgrades** for automatic security patches

## Hardening

The setup script installs a systemd hardening drop-in for each runner service:

- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectControlGroups=true`
- `ProtectKernelModules=true`
- `ProtectKernelTunables=true`
- `RestrictSUIDSGID=true`

If the hardening causes the runner to fail on startup, the script automatically
removes the drop-in and restarts without it.

## Maintenance

The setup script configures automatic maintenance:

- **Docker cleanup**: Weekly prune of unused images older than 7 days (Sunday 3 AM)
- **Workspace cleanup**: Monthly cleanup of old temp directories (1st of month, 4 AM)
- **Security updates**: `unattended-upgrades` service enabled
- **Runner auto-updates**: The runner agent auto-updates when GitHub releases a
  new version, causing a brief (~30 s) restart
- **Cleanup logs**: Written to `/opt/actions-runner/logs/` (or per-instance logs dir)

### Manual cleanup
```bash
docker system prune -af
df -h /opt/actions-runner
du -sh /opt/actions-runner/_work
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Jobs queue indefinitely | Runner offline or label mismatch | Check service status; verify `RUNNER_LABELS` matches runner labels |
| Runner shows "Idle" but jobs wait | NAT/firewall dropping long-poll connection | Lower TCP keepalive: `net.ipv4.tcp_keepalive_time=60` in `/etc/sysctl.d/99-runner-keepalive.conf`; run `sysctl --system`; restart runners |
| Job fails with "tool not found" | Missing dependency on runner | Re-run setup script or install manually |
| Docker permission denied | Runner user not in docker group | `sudo usermod -aG docker runner && sudo systemctl restart actions.runner.*` |
| Disk space exhaustion | Docker images / build artifacts | Run `docker system prune -af`; check cleanup cron is active |
| Firestore emulator won't start | Java not installed or wrong version | Verify `java -version` shows 21+; re-run setup script |
| Runner install fails on checksum | Download mismatch or network interception | Re-run setup; investigate network/proxy |

## Network: TCP Keepalive

If the runner VM is behind NAT, the default Linux TCP keepalive (2 hours) is too
slow — the NAT gateway drops the runner's long-poll connection before a keepalive
probe is sent. Apply this fix:

```bash
cat <<EOF | sudo tee /etc/sysctl.d/99-runner-keepalive.conf
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
EOF
sudo sysctl --system
```
