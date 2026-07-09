#!/usr/bin/env bash
#
# CI/CD Blueprint - cok servisli blue-green deploy/rollback yardimcisi
# CI/CD Blueprint - multi-service blue-green deploy/rollback helpe
#
# DEPLOY_TARGET:
#   local  - runner ve uygulama ayni makinede (varsayilan / default)
#   remote - uzak Linux sunucuya SSH ile deploy / deploy via SSH to remote Linux
#
# SERVICES formati / format (her satir bir servis / one service per line):
#   name|csproj|deploy_dir|service_name|health_url
#
#   health_url: nginx'in dinledigi public port ve health path'i icermeli.
#   health_url: must contain the public port nginx listens on and the health path.
#   Ornek / Example: http://IP:5000/health
#
# Blue-green modeli / Blue-green model:
#   Her servis icin iki dizin (deploy_dir-blue, deploy_dir-green) ve iki systemd
#   birimi (service_name-blue, service_name-green) vardir. nginx aktif renge
#   Unix socket uzerinden trafik iletir. Deploy idle renge yazar; saglik gecince
#   nginx graceful reload ile aktif renge gecer. Eski renk ayakta kalir (anlik rollback).
#
#   Two directories (deploy_dir-blue, deploy_dir-green) and two systemd units
#   (service_name-blue, service_name-green) exist per service. nginx forwards
#   traffic to the active color via Unix socket. Deploy writes to the idle color;
#   on health pass nginx graceful-reloads to make it active. Old color stays up
#   as an instant rollback target.
#
# Uzak deploy icin ek / For remote deploy also:
#   SSH_HOST, SSH_USER, SSH_PRIVATE_KEY (secret), SSH_KNOWN_HOSTS (zorunlu / required)
#   SSH_PORT (opsiyonel / optional)
#
# Kullanim / Usage:
#   bash pipeline.sh <deploy-artifacts|publish-source|write-env|write-info|restart|health|switch|rollback>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-Release}"
DEPLOY_TARGET="${DEPLOY_TARGET:-local}"

# shellcheck source=ssh-remote.sh
source "${SCRIPT_DIR}/ssh-remote.sh"
ssh_remote_init

services_lines() {
  printf '%s\n' "${SERVICES:?SERVICES ortam degiskeni tanimli degil / SERVICES env not set}" \
    | grep -vE '^\s*(#.*)?$'
}

# NOT: Asagidaki servis donguleri 'read <&3' + '3< <(services_lines)' kullanir.
# Gerekce: dongu govdesindeki ssh/rsync stdin'i (FD 0) okur; eger dongu stdin'den
# beslenseydi ssh kalan servis satirlarini yutar ve yalnizca ilk servis islenirdi.
# FD 3 ayrimi bu yuzden zorunludur (uzak/remote deploy'da coklu servis icin).
# NOTE: The service loops below use 'read <&3' + '3< <(services_lines)'. Reason: ssh/rsync
# in the loop body reads stdin (FD 0); if the loop were fed from stdin, ssh would consume the
# remaining service lines and only the first service would be processed. The FD 3 separation
# is therefore required (for multi-service remote deploys).

field() {
  printf '%s' "$1" | cut -d'|' -f"$2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# -------------------------------------------------------------------------
# Alan dogrulamasi / Field validation
# deploy_dir Unix yolu: sadece harf, rakam, /, _, ., @, - karakterlerine izin verilir.
# service_name sistemd birimi: sadece harf, rakam, _, ., @, - karakterlerine izin verilir.
# deploy_dir Unix path: only letters, digits, /, _, ., @, - are allowed.
# service_name systemd unit: only letters, digits, _, ., @, - are allowed.
# -------------------------------------------------------------------------
validate_path_field() {
  local val="$1" label="$2"
  if [ -z "$val" ]; then
    echo "HATA / ERROR: SERVICES alani '$label' bos olamaz / must not be empty"
    exit 1
  fi
  if ! printf '%s' "$val" | grep -qE '^[a-zA-Z0-9/_.@-]+$'; then
    echo "HATA / ERROR: SERVICES alani '$label' gecersiz karakter iceriyor / contains invalid character: '$val'"
    echo "  Yalnizca izin verilenler / only allowed: harf, rakam, /, _, ., @, -"
    exit 1
  fi
}

validate_name_field() {
  local val="$1" label="$2"
  if [ -z "$val" ]; then
    echo "HATA / ERROR: SERVICES alani '$label' bos olamaz / must not be empty"
    exit 1
  fi
  if ! printf '%s' "$val" | grep -qE '^[a-zA-Z0-9_.@-]+$'; then
    echo "HATA / ERROR: SERVICES alani '$label' gecersiz karakter iceriyor / contains invalid character: '$val'"
    echo "  Yalnizca izin verilenler / only allowed: harf, rakam, _, ., @, -"
    exit 1
  fi
}

# SERVICES satirlarindaki tum alanlari baslamadan once dogrula.
# Validates all SERVICES fields before any command runs.
validate_services() {
  while IFS= read -r line <&3; do
    local name dd svc
    name="$(field "$line" 1)"
    dd="$(field   "$line" 3)"
    svc="$(field  "$line" 4)"
    validate_name_field "$name" "name (alan 1)"
    validate_path_field "$dd"   "deploy_dir (alan 3)"
    validate_name_field "$svc"  "service_name (alan 4)"
  done 3< <(services_lines)
}

# -------------------------------------------------------------------------
# Blue-green renk yardimcilari / Blue-green color helpers
# -------------------------------------------------------------------------

# Aktif renk durum dosyasi — kesin kaynak (source of truth).
# nginx upstream metnini grep'lemek yerine ayri, tek-degerli bir durum dosyasi
# kullaniriz. Boylece (a) servis adinda "blue"/"green" gecmesi yaniltmaz,
# (b) nginx reload basarisiz olursa state guncellenmez (yaz-sonra-reload yerine
# reload-sonra-yaz), diskteki state ile calisan nginx tutarli kalir.
# Active-color state file — the source of truth. Instead of grepping the nginx
# upstream text we keep a separate single-value state file. This means (a) a
# service name containing "blue"/"green" cannot mislead detection, and (b) if the
# nginx reload fails the state is not updated (we write AFTER a successful reload,
# not before), so the on-disk state stays consistent with the running nginx.
state_file_for() { printf '/etc/nginx/cicd/%s.active' "$1"; }

# Aktif rengi durum dosyasindan okur.
# Reads the active color from the state file.
color_active() {
  local svc="$1"
  local sf; sf="$(state_file_for "$svc")"
  local c=""
  if is_remote; then
    c="$(remote_ssh "cat '$sf' 2>/dev/null" 2>/dev/null)" || c=""
  else
    c="$(cat "$sf" 2>/dev/null)" || c=""
  fi
  # Yalnizca gecerli deger kabul; degilse blue varsay (ilk deploy oncesi).
  # Accept only valid values; otherwise assume blue (pre-first-deploy).
  case "$c" in
    blue|green) printf '%s' "$c" ;;
    *)          printf 'blue' ;;
  esac
}

# Aktif renk durumunu yazar. YALNIZCA basarili nginx reload'dan SONRA cagrilmali.
# Writes the active-color state. Must be called ONLY AFTER a successful nginx reload.
write_active_color() {
  local svc="$1" color="$2"
  local sf; sf="$(state_file_for "$svc")"
  if is_remote; then
    local tmp
    tmp="$(remote_ssh "mktemp /tmp/cicd-state-XXXXXX")"
    remote_write_file "$color" "$tmp" 644
    remote_sudo "mv '$tmp' '$sf' && chmod 644 '$sf'"
  else
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$color" > "$tmp"
    mv "$tmp" "$sf"
    chmod 644 "$sf"
  fi
}

# Hedef renk: aktif rengin tersi.
# Target color: opposite of the active color.
color_target() {
  local svc="$1"
  local active; active="$(color_active "$svc")"
  if [ "$active" = "blue" ]; then printf 'green'; else printf 'blue'; fi
}

# Yardimci turetici fonksiyonlar / Derived path helpers
dir_for()  { printf '%s-%s' "$1" "$2"; }                     # (deploy_dir, color) -> deploy_dir-color
unit_for() { printf '%s-%s' "$1" "$2"; }                     # (svc, color) -> svc-color
sock_for() { printf '/run/cicd/%s-%s.sock' "$1" "$2"; }      # (svc, color) -> socket path
# Servis hesabi adi: setup-host.sh ile ayni konvansiyon (dusuk yetkili, login yok).
# Service account name: same convention as setup-host.sh (low-privilege, no login).
svc_user_for() { printf 'cicd-%s' "$1"; }                    # (svc) -> cicd-svc

# -------------------------------------------------------------------------
# SSH yardimcilari / SSH target helpers
# -------------------------------------------------------------------------

target_dir_exists() {
  local path="$1"
  if is_remote; then
    remote_path_exists "$path"
  else
    [ -d "$path" ]
  fi
}

# Dosya var mi (rollback DLL dogrulamasi icin) / whether a file exists (rollback DLL validation)
target_file_exists() {
  local path="$1"
  if is_remote; then
    remote_ssh "[ -f '$path' ]"
  else
    [ -f "$path" ]
  fi
}

# health_url'den yalnizca path / extract path from health_url only
health_path_from_url() {
  local url="$1"
  printf '%s' "$url" | sed -E 's#https?://[^/]+(/.+)$#\1#;t;s#.*#/health#'
}

# csproj yolundan publish DLL adi (setup-host.sh ile ayni) / publish DLL name from csproj path
dll_for_csproj() {
  local csproj="$1"
  local base
  base="$(basename "$csproj" .csproj)"
  printf '%s.dll' "$base"
}

target_publish_dir() {
  local staging="$1"
  local dest="$2"
  if is_remote; then
    # Dizini root ile olustur, deploy kullanicisina devret (rsync yazabilsin).
    # rsync sonrasi grup cicd + 750/640: servis kullanicisi CHDIR okuyabilsin.
    # Create as root, hand to deploy user for rsync. After rsync set group cicd
    # and 750/640 so the service account can CHDIR and read binaries.
    remote_sudo "mkdir -p '$dest' && chown -R '${SSH_USER}':'${SSH_USER}' '$dest'"
    remote_rsync "${staging}/" "${dest}/"
    remote_sudo "chown -R '${SSH_USER}:cicd' '${dest}' && find '${dest}' -type d -exec chmod 750 {} + && find '${dest}' -type f -exec chmod 640 {} +"
  else
    mkdir -p "$dest"
    rsync -a --delete "${staging}/" "${dest}/"
    chown -R "${SSH_USER:-root}:cicd" "${dest}" 2>/dev/null || true
    find "${dest}" -type d -exec chmod 750 {} + 2>/dev/null || true
    find "${dest}" -type f -exec chmod 640 {} + 2>/dev/null || true
  fi
}

target_write_env_one() {
  local dest_dir="$1"
  local content="$2"
  local svc_user="$3"
  # .env, servisi calistiran dusuk yetkili kullanici (svc_user) tarafindan
  # okunabilmelidir (EnvironmentFile). Sahip svc_user, grup cicd, mod 0640.
  # The .env must be readable by the low-privilege service account (svc_user)
  # that runs the unit (EnvironmentFile). Owner svc_user, group cicd, mode 0640.
  if is_remote; then
    remote_sudo "mkdir -p '$dest_dir'"
    # mktemp ile rassal gecici yol; PID-tabanli /tmp/cicd-env-$$ yerine kullanilir (TMP-01).
    # Use mktemp for an unpredictable temp path instead of PID-based /tmp/cicd-env-$$ (TMP-01).
    local tmp
    tmp="$(remote_ssh "mktemp /tmp/cicd-env-XXXXXX")"
    remote_write_file "$content" "$tmp" 600
    remote_sudo "mv '$tmp' '${dest_dir}/.env' && chmod 640 '${dest_dir}/.env' && chown '${svc_user}:cicd' '${dest_dir}/.env'"
  else
    [ -d "$dest_dir" ] || return 0
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$content" > "$tmp"
    mv "$tmp" "${dest_dir}/.env"
    chmod 640 "${dest_dir}/.env"
    # Local modda runner genelde root'tur; degilse chown best-effort.
    # In local mode the runner is usually root; otherwise chown is best-effort.
    chown "${svc_user}:cicd" "${dest_dir}/.env" 2>/dev/null || true
  fi
}

target_write_info_one() {
  local dest_dir="$1"
  local info="$2"
  if is_remote; then
    remote_sudo "mkdir -p '$dest_dir'"
    remote_write_file "$info" "${dest_dir}/.deploy-info" 644
  else
    [ -d "$dest_dir" ] || return 0
    printf '%s' "$info" > "${dest_dir}/.deploy-info"
  fi
}

target_stop_one() {
  local unit="$1"
  # Idle renk deploy oncesi durdurulur: calisan surec DLL kilidi rsync/publish'i bozabilir.
  # Stop idle color before deploy: a running process can lock DLLs and break rsync/publish.
  if is_remote; then
    remote_sudo "systemctl stop '${unit}' || true"
    remote_sudo_stdin "$unit" <<'STOPWAIT'
unit="$1"
for _ in $(seq 1 20); do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    sleep 1
  else
    exit 0
  fi
done
exit 1
STOPWAIT
  else
    systemctl stop "$unit" || true
    for _ in $(seq 1 20); do
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        sleep 1
      else
        return 0
      fi
    done
    return 1
  fi
}

target_restart_one() {
  local unit="$1"
  # systemd birim, surecin yasam dongusunu yonetir: restart eskisini (cgroup ile) durdurup
  # yenisini baslatir. Blue-green'de yalnizca IDLE rengin birimi yeniden baslatilir;
  # aktif (canli) renk etkilenmez.
  # systemd manages the process lifecycle. In blue-green only the IDLE color unit
  # is restarted; the active (live) color is not touched.
  if is_remote; then
    remote_sudo "systemctl restart '${unit}'"
  else
    systemctl restart "$unit"
  fi
}

# Idle rengin socketini kontrol et (lokal veya uzakta) / Health-check via idle color socket
# Args: sock_path health_path
target_health_socket_one() {
  local sock="$1"
  local health_path="$2"

  if is_remote; then
    # Scripti uzak host'ta root olarak calistir; FD 0 (stdin) dongu FD 3'ten ayridir.
    # Root gerekli: idle renk socketi root:cicd 0660; deploy kullanicisi erisemez.
    # Run script as root on the remote host; FD 0 (stdin) is separate from the loop's FD 3.
    # Root is required: the idle color socket is root:cicd 0660; the deploy user can't reach it.
    remote_sudo_stdin "$sock" "$health_path" <<'HEALTHCHECK'
sock="$1"; hp="$2"; m=12; w=5
for i in $(seq 1 "$m"); do
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    --unix-socket "$sock" "http://localhost${hp}" 2>/dev/null || echo 000)"
  if [ "$c" = "200" ]; then
    printf 'saglikli/healthy (%s/%s): %s\n' "$i" "$m" "$sock"
    exit 0
  fi
  printf 'bekleniyor/waiting (%s/%s) %ss...\n' "$i" "$m" "$w"
  sleep "$w"
done
printf 'saglik basarisiz/health failed: %s\n' "$sock"
exit 1
HEALTHCHECK
  else
    local m=12 w=5
    for i in $(seq 1 "$m"); do
      local c
      c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        --unix-socket "$sock" "http://localhost${health_path}" 2>/dev/null || echo 000)"
      if [ "$c" = "200" ]; then
        printf 'saglikli/healthy (%s/%s): %s\n' "$i" "$m" "$sock"
        return 0
      fi
      printf 'bekleniyor/waiting (%s/%s) %ss...\n' "$i" "$m" "$w"
      sleep "$w"
    done
    printf 'saglik basarisiz/health failed: %s\n' "$sock"
    return 1
  fi
}

# nginx upstream include dosyasini yeni renge yazar / Writes new color to nginx upstream include
nginx_write_upstream() {
  local svc="$1"
  local color="$2"
  local include_file="/etc/nginx/cicd/${svc}-upstream.conf"
  local content
  content="upstream cicd_${svc} {
    server unix:/run/cicd/${svc}-${color}.sock;
    keepalive 32;
}"
  if is_remote; then
    # /etc/nginx/cicd root sahiplidir ve oyle kalmali (sistem dizini). Deploy
    # kullanicisi oraya dogrudan yazamaz; once /tmp'e yaz, sonra sudo ile tasi.
    # /etc/nginx/cicd is root-owned and must stay so (system dir). The deploy
    # user cannot write there directly; write to /tmp first, then sudo-move.
    local tmp
    tmp="$(remote_ssh "mktemp /tmp/cicd-upstream-XXXXXX")"
    remote_write_file "$content" "$tmp" 644
    remote_sudo "mv '$tmp' '$include_file' && chmod 644 '$include_file'"
  else
    # Atomik yazim: gecici dosyaya yaz, sonra rename. Yarim yazilmis include olmaz.
    # Atomic write: write to a temp file, then rename. No half-written include.
    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$content" > "$tmp"
    mv "$tmp" "$include_file"
    chmod 644 "$include_file"
  fi
}

# nginx yapilandirmasini test et ve graceful reload yap / Test and graceful-reload nginx
# ONEMLI: 'nginx -t' basarisiz olursa fonksiyon MUTLAKA hata donmeli. Aksi halde
# cagiran (cmd_switch/cmd_rollback) reload basarisizken aktif renk state'ini yazar ve
# disk state'i ile canli nginx tutarsiz kalir (STATE-01/A). Trailing echo bir AND-OR
# listesinin ardindan geldiginde 'set -e' devreye girmedigi icin durumu acikca ele aliriz.
#
# IMPORTANT: if 'nginx -t' fails this function MUST return non-zero. Otherwise the calle
# (cmd_switch/cmd_rollback) would persist the active-color state while the reload failed,
# leaving the on-disk state inconsistent with the live nginx (STATE-01/A). Because 'set -e'
# is not triggered by an AND-OR list followed by another command, we handle it explicitly.
nginx_reload() {
  local ok=0
  if is_remote; then
    remote_sudo "nginx -t && nginx -s reload" || ok=1
  else
    { nginx -t && nginx -s reload; } || ok=1
  fi
  if [ "$ok" -ne 0 ]; then
    echo "HATA: nginx yapilandirma testi/reload basarisiz / nginx config test or reload failed" >&2
    return 1
  fi
  echo "nginx graceful reload tamam / done"
}

# Kaydedilmis aktif renklere upstream geri yukle + reload (hata kurtarma).
# Revert upstream includes to saved active colors + reload (failure recovery).
revert_upstreams_saved() {
  local revert_file="$1"
  while IFS='|' read -r svc active || [ -n "${svc:-}" ]; do
    [ -z "${svc:-}" ] && continue
    nginx_write_upstream "$svc" "$active"
    echo "upstream geri alindi / reverted: ${svc} -> ${active}"
  done < "$revert_file"
  nginx_reload || echo "UYARI / WARNING: geri alma reload basarisiz / revert reload failed" >&2
}

# Hedef (idle veya rollback) renge trafik gecisi: upstream -> reload -> state.
# Gecis basarisiz olursa upstream diskini kaydedilen aktif renge geri alir (canli nginx korunur).
# Switch traffic to target (idle or rollback) color: upstream -> reload -> state.
# On failure, reverts on-disk upstream to the saved active color (live nginx preserved).
switch_traffic_to_idle() {
  local revert_file state_fail=0
  revert_file="$(mktemp)"

  while IFS= read -r line <&3; do
    local svc active
    svc="$(field "$line" 4)"
    active="$(color_active "$svc")"
    printf '%s|%s\n' "$svc" "$active" >> "$revert_file"
  done 3< <(services_lines)

  while IFS= read -r line <&3; do
    local svc color
    svc="$(field "$line" 4)"
    color="$(color_target "$svc")"
    nginx_write_upstream "$svc" "$color"
    echo "upstream guncellendi / updated: ${svc} -> ${color}"
  done 3< <(services_lines)

  if ! nginx_reload; then
    echo "HATA: nginx reload basarisiz; upstream ve canli trafik onceki renkte tutuluyor." >&2
    echo "ERROR: nginx reload failed; upstream and live traffic kept on previous color." >&2
    revert_upstreams_saved "$revert_file"
    rm -f "$revert_file"
    return 1
  fi

  set +e
  while IFS= read -r line <&3; do
    local svc color wrc
    svc="$(field "$line" 4)"
    color="$(color_target "$svc")"
    write_active_color "$svc" "$color"
    wrc=$?
    if [ "$wrc" -ne 0 ]; then
      state_fail=1
    fi
  done 3< <(services_lines)
  set -e

  if [ "$state_fail" -ne 0 ]; then
    echo "HATA: aktif renk state yazilamadi; upstream geri aliniyor." >&2
    echo "ERROR: failed to persist active-color state; reverting upstream." >&2
    revert_upstreams_saved "$revert_file"
    rm -f "$revert_file"
    return 1
  fi

  rm -f "$revert_file"
  return 0
}

# -------------------------------------------------------------------------
# Pipeline komutlari / Pipeline commands
# -------------------------------------------------------------------------

cmd_publish_source() {
  while IFS= read -r line <&3; do
    local csproj dd svc color target_dd staging
    csproj="$(field "$line" 2)"
    dd="$(field    "$line" 3)"
    svc="$(field   "$line" 4)"
    color="$(color_target "$svc")"
    target_dd="$(dir_for "$dd" "$color")"
    unit="$(unit_for "$svc" "$color")"
    staging="$(mktemp -d)"
    target_stop_one "$unit"
    dotnet publish "$csproj" --configuration "$CONFIG" --output "$staging" /p:UseSharedCompilation=false
    target_publish_dir "$staging" "$target_dd"
    rm -rf "$staging"
    echo "yayinlandi (kaynaktan) / published (source): $csproj -> $target_dd"
  done 3< <(services_lines)
}

cmd_deploy_artifacts() {
  : "${ARTIFACT_ROOT:?ARTIFACT_ROOT tanimli degil / not set}"
  while IFS= read -r line <&3; do
    local name dd svc color target_dd src
    name="$(field "$line" 1)"
    dd="$(field   "$line" 3)"
    svc="$(field  "$line" 4)"
    color="$(color_target "$svc")"
    target_dd="$(dir_for "$dd" "$color")"
    unit="$(unit_for "$svc" "$color")"
    src="${ARTIFACT_ROOT}/${name}"
    if [ ! -d "$src" ]; then
      echo "artifact bulunamadi / artifact not found: $src"
      exit 1
    fi
    target_stop_one "$unit"
    target_publish_dir "$src" "$target_dd"
    echo "yayinlandi (artifact) / published (artifact): $src -> $target_dd"
  done 3< <(services_lines)
}

cmd_write_env() {
  if [ -z "${APP_ENV:-}" ]; then
    echo "APP_ENV bos, atlaniyor / empty, skipped"
    return 0
  fi
  while IFS= read -r line <&3; do
    local dd svc color target_dd svc_user
    dd="$(field  "$line" 3)"
    svc="$(field "$line" 4)"
    color="$(color_target "$svc")"
    target_dd="$(dir_for "$dd" "$color")"
    svc_user="$(svc_user_for "$svc")"
    target_write_env_one "$target_dd" "$APP_ENV" "$svc_user"
    echo "gizli ortam yazildi / secret env written: ${target_dd}/.env"
  done 3< <(services_lines)
}

cmd_write_info() {
  while IFS= read -r line <&3; do
    local dd svc color target_dd info
    dd="$(field  "$line" 3)"
    svc="$(field "$line" 4)"
    color="$(color_target "$svc")"
    target_dd="$(dir_for "$dd" "$color")"
    info="deploy_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=${GIT_SHA:-unknown}
deployed_by=${DEPLOYED_BY:-unknown}
deploy_target=${DEPLOY_TARGET}
color=${color}
note=${DEPLOY_NOTE:-}"
    target_write_info_one "$target_dd" "$info"
    echo "deploy bilgisi yazildi / deploy info written: ${target_dd}/.deploy-info"
  done 3< <(services_lines)
}

cmd_restart() {
  # Yalnizca IDLE rengin birimini yeniden baslatir; AKTIF renk dokunulmaz.
  # Restarts only the IDLE color unit; the ACTIVE color unit is not touched.
  while IFS= read -r line <&3; do
    local svc color unit
    svc="$(field "$line" 4)"
    color="$(color_target "$svc")"
    unit="$(unit_for "$svc" "$color")"
    target_restart_one "$unit"
    echo "yeniden baslatildi / restarted: $unit"
  done 3< <(services_lines)
}

cmd_health() {
  # Idle rengin socketini dogrudan kontrol eder (nginx devreye girmeden once).
  # Checks the idle color socket directly (before nginx is switched).
  local fail=0
  while IFS= read -r line <&3; do
    local svc url color sock health_path
    svc="$(field "$line" 4)"
    url="$(field "$line" 5)"
    color="$(color_target "$svc")"
    sock="$(sock_for "$svc" "$color")"
    health_path="$(health_path_from_url "$url")"
    echo "saglik kontrolu / health check: $sock ($health_path)"
    if ! target_health_socket_one "$sock" "$health_path"; then
      fail=1
    fi
  done 3< <(services_lines)
  return "$fail"
}

cmd_switch() {
  switch_traffic_to_idle || return 1
  echo "trafik gecisi tamam / traffic switched"
}

cmd_health_active() {
  # Aktif rengin socketini kontrol eder — rollback dogrulamasi icin kullanilir.
  # Checks the ACTIVE color's socket — used for post-rollback verification.
  local fail=0
  while IFS= read -r line <&3; do
    local svc url color sock health_path
    svc="$(field "$line" 4)"
    url="$(field "$line" 5)"
    color="$(color_active "$svc")"
    sock="$(sock_for "$svc" "$color")"
    health_path="$(health_path_from_url "$url")"
    echo "saglik kontrolu (aktif renk) / health check (active color): $sock ($health_path)"
    if ! target_health_socket_one "$sock" "$health_path"; then
      fail=1
    fi
  done 3< <(services_lines)
  return "$fail"
}

cmd_rollback() {
  # Blue-green rollback: hedef renge gecmeden once dogrula + saglik kontrolu, sonra gecis.
  # Blue-green rollback: validate + health-check before switching, then switch traffic.
  # Sifir kesinti: aktif renk kapanmaz; nginx yalnizca yonlendirmeyi degistirir.
  #
  # Fazlar / Phases:
  #   1) DOGRULA: rollback dizini + publish DLL mevcut mu (yazma yok).
  #   2) SAGLIK: hedef renk socket'i saglikli mi (switch oncesi).
  #   3) GECIS: switch_traffic_to_idle (upstream -> reload -> state; hata olursa geri al).
  local fail=0

  # 1. DOGRULAMA — dizin + DLL (bos klasor ile rollback engellenir).
  while IFS= read -r line <&3; do
    local csproj dd svc dll rollback_color rollback_dir
    csproj="$(field "$line" 2)"
    dd="$(field  "$line" 3)"
    svc="$(field "$line" 4)"
    dll="$(dll_for_csproj "$csproj")"
    rollback_color="$(color_target "$svc")"
    rollback_dir="$(dir_for "$dd" "$rollback_color")"
    if ! target_dir_exists "$rollback_dir"; then
      echo "HATA / ERROR: Rollback hedefi bulunamadi (ilk deploy'dan once geri alinamaz)."
      echo "  No rollback target: ${rollback_dir} (cannot roll back before the first deploy)"
      fail=1
      continue
    fi
    if ! target_file_exists "${rollback_dir}/${dll}"; then
      echo "HATA / ERROR: Rollback hedefinde uygulama dosyasi yok / no application in rollback target."
      echo "  Missing: ${rollback_dir}/${dll}"
      fail=1
    fi
  done 3< <(services_lines)

  if [ "$fail" -ne 0 ]; then
    echo "Rollback iptal — hicbir degisiklik yapilmadi. / Rollback aborted — no changes were made."
    return 1
  fi

  # 2. SAGLIK — switch oncesi hedef renk (onceki surum) socket kontrolu.
  while IFS= read -r line <&3; do
    local svc url rollback_color sock health_path
    svc="$(field "$line" 4)"
    url="$(field "$line" 5)"
    rollback_color="$(color_target "$svc")"
    sock="$(sock_for "$svc" "$rollback_color")"
    health_path="$(health_path_from_url "$url")"
    echo "rollback on saglik kontrolu / pre-rollback health: $sock ($health_path)"
    if ! target_health_socket_one "$sock" "$health_path"; then
      echo "HATA / ERROR: Rollback hedefi sagliksiz; trafik degistirilmeyecek."
      echo "  Rollback target unhealthy; traffic will NOT be switched."
      fail=1
    fi
  done 3< <(services_lines)

  if [ "$fail" -ne 0 ]; then
    echo "Rollback iptal — hicbir degisiklik yapilmadi. / Rollback aborted — no changes were made."
    return 1
  fi

  # 3. GECIS — upstream + reload + state (hata olursa otomatik geri alma).
  switch_traffic_to_idle || return 1
  echo "rollback tamamlandi / rollback complete — trafik anlık cevirildi / traffic switched instantly"
}

# -------------------------------------------------------------------------
# main
# -------------------------------------------------------------------------
main() {
  local command="${1:-}"
  case "$command" in
    publish-source|deploy-artifacts|write-env|write-info|restart|health|health-active|switch|rollback)
      validate_services
      ;;
    *)
      echo "kullanim / usage: DEPLOY_TARGET=local|remote SERVICES=... bash pipeline.sh <command>"
      echo "  komutlar / commands: publish-source deploy-artifacts write-env write-info restart health health-active switch rollback"
      exit 1
      ;;
  esac
  case "$command" in
    publish-source)   cmd_publish_source ;;
    deploy-artifacts) cmd_deploy_artifacts ;;
    write-env)        cmd_write_env ;;
    write-info)       cmd_write_info ;;
    restart)          cmd_restart ;;
    health)           cmd_health ;;
    health-active)    cmd_health_active ;;
    switch)           cmd_switch ;;
    rollback)         cmd_rollback ;;
  esac
}

main "$@"
