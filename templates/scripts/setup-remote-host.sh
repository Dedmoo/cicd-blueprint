#!/usr/bin/env bash
#
# CI/CD Blueprint - uzak sunucuda tek seferlik host kurulumu
# CI/CD Blueprint - one-time host setup on a remote server via SSH
#
# Uzak sunucuda systemd birimlerini olusturur (setup-host.sh'yi SSH ile calistirir).
# Creates systemd units on the remote server (runs setup-host.sh over SSH).
#
# Gerekli / Required:
#   SERVICES, SSH_HOST, SSH_USER, SSH_PRIVATE_KEY, SSH_KNOWN_HOSTS
# Opsiyonel / Optional: SSH_PORT
#
# Kullanim / Usage:
#   DEPLOY_TARGET=remote SSH_HOST=10.0.0.5 SSH_USER=deploy \
#     SSH_PRIVATE_KEY="$(cat deploy_key)" SERVICES="..." \
#     bash scripts/setup-remote-host.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_TARGET=remote
export DEPLOY_TARGET

# shellcheck source=ssh-remote.sh
source "${SCRIPT_DIR}/ssh-remote.sh"
ssh_remote_init

echo "Uzak sunucuda kurulum basliyor / starting remote setup: ${SSH_TARGET}"

rsync -az -e "$RSYNC_SSH" "${SCRIPT_DIR}/setup-host.sh" "${SSH_TARGET}:/tmp/cicd-setup-host.sh"
remote_ssh "chmod +x /tmp/cicd-setup-host.sh"

svc_file="$(mktemp)"
printf '%s\n' "$SERVICES" > "$svc_file"
rsync -az -e "$RSYNC_SSH" "$svc_file" "${SSH_TARGET}:/tmp/cicd-services.txt"
rm -f "$svc_file"

remote_sudo "SERVICES=\$(cat /tmp/cicd-services.txt) bash /tmp/cicd-setup-host.sh"
remote_ssh "rm -f /tmp/cicd-setup-host.sh /tmp/cicd-services.txt"

echo "Uzak kurulum tamam / remote setup done."
