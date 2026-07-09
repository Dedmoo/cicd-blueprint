#!/usr/bin/env bash
# E2E: ensure-infra adiminin calistigini dogrular (migration marker yazar).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/templates/scripts"
DEPLOY_TARGET="${DEPLOY_TARGET:-local}"
MARKER="/var/lib/cicd-e2e-migration.marker"

write_marker() {
  if [ "$DEPLOY_TARGET" = "remote" ]; then
    # shellcheck source=ssh-remote.sh
    source "${SCRIPT_DIR}/ssh-remote.sh"
    ssh_remote_init
    remote_sudo "mkdir -p /var/lib && touch '${MARKER}' && chmod 644 '${MARKER}'"
  else
    sudo mkdir -p /var/lib
    sudo touch "$MARKER"
  fi
  echo "migration marker yazildi / written: ${MARKER}"
}

write_marker
