#!/usr/bin/env bash
#
# CI/CD Blueprint - uzak sunucu SSH yardimcilari
# CI/CD Blueprint - remote server SSH helpers
#
# DEPLOY_TARGET=remote iken pipeline.sh tarafindan source edilir.
# Sourced by pipeline.sh when DEPLOY_TARGET=remote.
#
# Gerekli ortam degiskenleri / Required env:
#   SSH_HOST, SSH_USER, SSH_PRIVATE_KEY, SSH_KNOWN_HOSTS
#   (SSH_KNOWN_HOSTS artik zorunlu — MITM korumasi / now required — MITM protection)
# Opsiyonel / Optional: SSH_PORT (22)

set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_FILE=""
SSH_CONTROL_PATH=""

is_remote() {
  [ "${DEPLOY_TARGET:-local}" = "remote" ]
}

ssh_remote_init() {
  if ! is_remote; then
    return 0
  fi

  : "${SSH_HOST:?SSH_HOST tanimli degil / not set}"
  : "${SSH_USER:?SSH_USER tanimli degil / not set}"
  : "${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY tanimli degil / not set}"

  if ! command -v ssh >/dev/null 2>&1; then
    echo "ssh bulunamadi / ssh not found"
    exit 1
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync bulunamadi / rsync not found"
    exit 1
  fi

  SSH_KEY_FILE="$(mktemp)"
  printf '%s\n' "$SSH_PRIVATE_KEY" > "$SSH_KEY_FILE"
  chmod 600 "$SSH_KEY_FILE"

  # SSH ControlMaster soket dosyasi: tekrar eden baglantilari yeniden kullanir,
  # blue-green renk tespiti icin yapilan cok sayida SSH cagrisini hizlandirir.
  # SSH ControlMaster socket: reuses connections, speeds up repeated SSH calls
  # needed for blue-green color detection across pipeline commands.
  SSH_CONTROL_PATH="$(mktemp -u "/tmp/cicd-ssh-XXXXXX")"

  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  local known_hosts="${HOME}/.ssh/known_hosts"
  # Port != 22 ise known_hosts anahtari [host]:port bicimindedir.
  # When port != 22, known_hosts keys use the [host]:port form.
  local hostspec="$SSH_HOST"
  if [ "$SSH_PORT" != "22" ]; then
    hostspec="[${SSH_HOST}]:${SSH_PORT}"
  fi

  # SSH_KNOWN_HOSTS ZORUNLUDUR. Onceki surumlerde bos birakilirsa ssh-keyscan ile
  # anahtar otomatik kabul ediliyordu (TOFU) — bu, ilk baglantida MITM'e acikti.
  # Artik guvenli host parmak izi onceden saglanmadan uzak deploy REDDEDILIR.
  # SSH_KNOWN_HOSTS is REQUIRED. Older versions auto-accepted the key via ssh-keyscan
  # (TOFU) when left empty — that was open to first-connection MITM. Remote deploy is
  # now REFUSED unless a trusted host fingerprint is supplied up front.
  if [ -z "${SSH_KNOWN_HOSTS:-}" ]; then
    echo "HATA / ERROR: SSH_KNOWN_HOSTS tanimli degil / not set."
    echo "  Uzak deploy icin sunucu host anahtari onceden verilmelidir (MITM korumasi)."
    echo "  Remote deploy requires the server host key up front (MITM protection)."
    echo "  Uretmek icin / generate with: ssh-keyscan -p ${SSH_PORT} ${SSH_HOST}"
    echo "  Ciktinin tamamini repo Variable 'SSH_KNOWN_HOSTS' olarak kaydedin."
    echo "  Save the full output as the repo Variable 'SSH_KNOWN_HOSTS'."
    exit 1
  fi
  # Her pipeline adiminda yeniden yazma; host zaten biliniyorsa atla.
  # Do not re-append on every pipeline step; skip if the host is already known.
  if ! ssh-keygen -F "$hostspec" -f "$known_hosts" >/dev/null 2>&1; then
    printf '%s\n' "$SSH_KNOWN_HOSTS" >> "$known_hosts"
  fi
  chmod 600 "$known_hosts" 2>/dev/null || true

  export SSH_TARGET="${SSH_USER}@${SSH_HOST}"
  export SSH_CMD=(ssh -i "$SSH_KEY_FILE" -p "$SSH_PORT"
    -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15
    -o ControlMaster=auto -o "ControlPath=${SSH_CONTROL_PATH}" -o ControlPersist=60s)
  export RSYNC_SSH="ssh -i ${SSH_KEY_FILE} -p ${SSH_PORT} \
    -o StrictHostKeyChecking=yes -o BatchMode=yes \
    -o ControlMaster=auto -o ControlPath=${SSH_CONTROL_PATH} -o ControlPersist=60s"

  echo "SSH hazir / ready: ${SSH_TARGET} (port ${SSH_PORT})"
}

ssh_remote_cleanup() {
  if [ -n "$SSH_KEY_FILE" ] && [ -f "$SSH_KEY_FILE" ]; then
    rm -f "$SSH_KEY_FILE"
  fi
  # ControlMaster soketini kapat / close the ControlMaster socket
  if [ -n "$SSH_CONTROL_PATH" ] && [ -S "$SSH_CONTROL_PATH" ]; then
    "${SSH_CMD[@]}" -O exit "$SSH_TARGET" 2>/dev/null || true
    rm -f "$SSH_CONTROL_PATH"
  fi
}

remote_ssh() {
  "${SSH_CMD[@]}" "$SSH_TARGET" "$@"
}

# Stdin'den okunan scripti uzak hostda root (sudo) olarak calistirir; positional
# arglar $1, $2, ... olarak iletilir. NOPASSWD sudo gerektirir (dokumante edilmis kosul).
# Socket saglik kontrolu icin kullanilir: idle renk socketi root:cicd 0660'tir; deploy
# kullanicisi cicd grubunda olmadigindan yalnizca root erisebilir.
# Runs a script read from stdin on the remote host as root (sudo); positional args are
# passed as $1, $2, ... Requires NOPASSWD sudo (documented requirement). Used for the
# socket health check: the idle color socket is root:cicd 0660; since the deploy user is
# not in the cicd group, only root can reach it.
# Usage: remote_sudo_stdin arg1 arg2 <<'SCRIPT' ... SCRIPT
remote_sudo_stdin() {
  "${SSH_CMD[@]}" "$SSH_TARGET" sudo bash -s -- "$@"
}

remote_sudo() {
  local cmd="$1"
  if [ -n "${SSH_SUDO_PASSWORD:-}" ]; then
    printf '%s\n' "$SSH_SUDO_PASSWORD" | "${SSH_CMD[@]}" "$SSH_TARGET" "sudo -S bash -c $(printf '%q' "$cmd")"
  else
    "${SSH_CMD[@]}" "$SSH_TARGET" "sudo bash -c $(printf '%q' "$cmd")"
  fi
}

remote_rsync() {
  local src="$1"
  local dest="$2"
  rsync -az --delete -e "$RSYNC_SSH" "${src}" "${SSH_TARGET}:${dest}"
}

remote_path_exists() {
  local path="$1"
  remote_ssh "[ -e '$path' ]"
}

remote_write_file() {
  local content="$1"
  local dest="$2"
  local mode="${3:-600}"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$content" > "$tmp"
  rsync -az -e "$RSYNC_SSH" "$tmp" "${SSH_TARGET}:${dest}"
  rm -f "$tmp"
  remote_ssh "chmod '$mode' '$dest'"
}

trap ssh_remote_cleanup EXIT
