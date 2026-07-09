#!/usr/bin/env bash
# Uzak sunucu simulasyonu: WSL'de localhost SSH + deploy kullanicisi kurar.
# Root ile calistir: sudo bash tests/remote-sim-setup.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "root gerekli: sudo bash tests/remote-sim-setup.sh"
  exit 1
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KEYDIR="$REPO/tests/.sim-keys"
SIM_USER="cicddeploy"

# sshd baslat
if command -v service >/dev/null 2>&1; then
  service ssh start 2>/dev/null || service sshd start 2>/dev/null || true
fi

# deploy kullanicisi
if ! id "$SIM_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$SIM_USER"
fi
echo "${SIM_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${SIM_USER}"
chmod 440 "/etc/sudoers.d/${SIM_USER}"
visudo -cf "/etc/sudoers.d/${SIM_USER}"

mkdir -p "$KEYDIR"
if [ ! -f "$KEYDIR/deploy_key" ]; then
  ssh-keygen -t ed25519 -N "" -f "$KEYDIR/deploy_key" -C "cicd-sim" >/dev/null
fi

mkdir -p "/home/${SIM_USER}/.ssh"
cp "$KEYDIR/deploy_key.pub" "/home/${SIM_USER}/.ssh/authorized_keys"
chown -R "${SIM_USER}:${SIM_USER}" "/home/${SIM_USER}/.ssh"
chmod 700 "/home/${SIM_USER}/.ssh"
chmod 600 "/home/${SIM_USER}/.ssh/authorized_keys"

HOST="$(hostname -I | awk '{print $1}')"
[ -n "$HOST" ] || HOST="127.0.0.1"

ssh-keyscan -p 22 "$HOST" 2>/dev/null > "$KEYDIR/known_hosts" || ssh-keyscan -p 22 127.0.0.1 > "$KEYDIR/known_hosts"

# baglanti testi
SSH_PRIVATE_KEY="$(cat "$KEYDIR/deploy_key")"
export SSH_PRIVATE_KEY
export SSH_KNOWN_HOSTS="$(cat "$KEYDIR/known_hosts")"
export SSH_HOST="$HOST"
export SSH_USER="$SIM_USER"
export SSH_PORT=22
export DEPLOY_TARGET=remote

# ssh-remote init test
bash -c '
  SCRIPT_DIR="'"$REPO"'/templates/scripts"
  source "$SCRIPT_DIR/ssh-remote.sh"
  ssh_remote_init
  remote_ssh "echo SIM_SSH_OK"
  remote_sudo "echo SIM_SUDO_OK"
'

echo "SIM_SETUP_OK host=$HOST user=$SIM_USER"
echo "KEYDIR=$KEYDIR"

# Eski mock curl temizligi (onceki remote-sim-test kalintisi).
if command -v ssh >/dev/null 2>&1 && [ -f "$KEYDIR/deploy_key" ]; then
  SSH_PRIVATE_KEY="$(cat "$KEYDIR/deploy_key")"
  export SSH_PRIVATE_KEY SSH_HOST="$HOST" SSH_USER="$SIM_USER" SSH_PORT=22
  export SSH_KNOWN_HOSTS="$(cat "$KEYDIR/known_hosts")"
  export DEPLOY_TARGET=remote
  bash -c '
    SCRIPT_DIR="'"$REPO"'/templates/scripts"
    source "$SCRIPT_DIR/ssh-remote.sh"
    ssh_remote_init
    remote_sudo "
      if [ -f /usr/local/bin/curl.real ]; then
        mv -f /usr/local/bin/curl.real /usr/local/bin/curl
        chmod +x /usr/local/bin/curl
      elif [ -f /usr/local/bin/curl ] && head -1 /usr/local/bin/curl | grep -q bash; then
        rm -f /usr/local/bin/curl
      fi
    " 2>/dev/null || true
  '
fi
