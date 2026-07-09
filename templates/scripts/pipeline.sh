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

target_publish_dir() {
  local staging="$1"
  local dest="$2"
  if is_remote; then
    # Dizini root ile olustur, sonra deploy kullanicisina devret: boylece rsync
    # (deploy kullanicisi olarak calisir) dizine yazabilir. chown, rsync'ten ONCE
    # yapilmali; aksi halde root sahipli dizine yazma "Permission denied" verir.
    # Create the dir as root, then hand it to the deploy user so rsync (which runs
    # as the deploy user) can write into it. chown MUST happen BEFORE rsync;
    # otherwise writing into a root-owned dir fails with "Permission denied".
    remote_sudo "mkdir -p '$dest' && chown -R '${SSH_USER}':'${SSH_USER}' '$dest'"
    remote_rsync "${staging}/" "${dest}/"
  else
    mkdir -p "$dest"
    rsync -a --delete "${staging}/" "${dest}/"
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
    staging="$(mktemp -d)"
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
    src="${ARTIFACT_ROOT}/${name}"
    if [ ! -d "$src" ]; then
      echo "artifact bulunamadi / artifact not found: $src"
      exit 1
    fi
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
    # health_path: URL'den sadece path'i cikart / extract only the path from URL
    health_path="$(printf '%s' "$url" | sed -E 's#https?://[^/]+(/.+)$#\1#;t;s#.*#/health#')"
    echo "saglik kontrolu / health check: $sock ($health_path)"
    if ! target_health_socket_one "$sock" "$health_path"; then
      fail=1
    fi
  done 3< <(services_lines)
  return "$fail"
}

cmd_switch() {
  # 1. Tum servislerin upstream include dosyalarini idle renge guncelle (state'e DOKUNMA).
  # 1. Update all upstream include files to the idle color (do NOT touch state yet).
  while IFS= read -r line <&3; do
    local svc color
    svc="$(field "$line" 4)"
    color="$(color_target "$svc")"
    nginx_write_upstream "$svc" "$color"
    echo "upstream guncellendi / updated: ${svc} -> ${color}"
  done 3< <(services_lines)

  # 2. Tek seferde nginx graceful reload / single graceful nginx reload.
  #    Basarisizsa set -e ile cikilir; state guncellenmedigi icin bir sonraki
  #    deploy hala dogru aktif rengi okur (canli nginx ile tutarli kalir).
  #    On failure set -e exits; since state is untouched, the next deploy still
  #    reads the correct active color (stays consistent with the live nginx).
  nginx_reload

  # 3. Reload BASARILI: aktif renk durumunu yeni renge yaz (kesin kaynak guncellenir).
  # 3. Reload SUCCEEDED: persist the new active color (update the source of truth).
  while IFS= read -r line <&3; do
    local svc color
    svc="$(field "$line" 4)"
    color="$(color_target "$svc")"
    write_active_color "$svc" "$color"
  done 3< <(services_lines)
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
    health_path="$(printf '%s' "$url" | sed -E 's#https?://[^/]+(/.+)$#\1#;t;s#.*#/health#')"
    echo "saglik kontrolu (aktif renk) / health check (active color): $sock ($health_path)"
    if ! target_health_socket_one "$sock" "$health_path"; then
      fail=1
    fi
  done 3< <(services_lines)
  return "$fail"
}

cmd_rollback() {
  # Blue-green rollback: nginx'i diger renge (onceki surum) cevir + graceful reload.
  # Blue-green rollback: switch nginx to the other color (previous version) + graceful reload.
  # Sifir kesinti: aktif renk kapanmaz; nginx yalnizca yonlendirmeyi degistirir.
  # Zero-downtime: the active color never goes down; nginx only changes routing.
  #
  # Rollback rengi = aktif rengin tersi = color_target. Islem 3 fazlidir ve
  # yarim-state olusmasini onler:
  #   1) DOGRULA: tum servislerin rollback dizini var mi (hicbir sey yazma).
  #   2) YAZ: tumu gecerliyse upstream include'lari rollback rengine yaz.
  #   3) RELOAD sonrasi: state dosyalarini guncelle (kesin kaynak).
  # Rollback color = opposite of active = color_target. Three phases prevent a
  # half-applied state: 1) VALIDATE all rollback dirs exist (no writes),
  # 2) WRITE upstreams only if all valid, 3) update state files AFTER reload.
  local fail=0

  # 1. DOGRULAMA fazi — hicbir dosya yazilmaz.
  # 1. VALIDATION phase — no files are written.
  while IFS= read -r line <&3; do
    local dd svc rollback_color rollback_dir
    dd="$(field  "$line" 3)"
    svc="$(field "$line" 4)"
    rollback_color="$(color_target "$svc")"
    rollback_dir="$(dir_for "$dd" "$rollback_color")"
    if ! target_dir_exists "$rollback_dir"; then
      echo "HATA / ERROR: Rollback hedefi bulunamadi (ilk deploy'dan once geri alinamaz)."
      echo "  No rollback target: ${rollback_dir} (cannot roll back before the first deploy)"
      fail=1
    fi
  done 3< <(services_lines)

  if [ "$fail" -ne 0 ]; then
    echo "Rollback iptal — hicbir degisiklik yapilmadi. / Rollback aborted — no changes were made."
    return 1
  fi

  # 2. YAZMA fazi — tum upstream include'lar rollback rengine.
  # 2. WRITE phase — all upstream includes to the rollback color.
  while IFS= read -r line <&3; do
    local svc rollback_color
    svc="$(field "$line" 4)"
    rollback_color="$(color_target "$svc")"
    nginx_write_upstream "$svc" "$rollback_color"
    echo "rollback upstream guncellendi / rollback upstream updated: ${svc} -> ${rollback_color}"
  done 3< <(services_lines)

  # 3. Reload; basarisizsa set -e ile cikilir, state guncellenmez.
  # 3. Reload; on failure set -e exits and state is left untouched.
  nginx_reload

  # 4. Reload BASARILI: aktif renk durumunu rollback rengine yaz.
  # 4. Reload SUCCEEDED: persist the rollback color as the active state.
  while IFS= read -r line <&3; do
    local svc rollback_color
    svc="$(field "$line" 4)"
    rollback_color="$(color_target "$svc")"
    write_active_color "$svc" "$rollback_color"
  done 3< <(services_lines)

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
