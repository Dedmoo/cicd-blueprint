#!/usr/bin/env bash
#
# CI/CD Blueprint - cok servisli deploy/rollback yardimcisi
# CI/CD Blueprint - multi-service deploy/rollback helper
#
# Tek yapilandirma kaynagi ortam degiskeni SERVICES'tir.
# Single source of configuration is the SERVICES environment variable.
#
#   SERVICES formati / format (her satir bir servis / one service per line):
#   name|csproj|deploy_dir|service_name|health_url
#
#   ornek / example:
#   web|src/Web/Web.csproj|/opt/myapp-web|myapp-web|http://127.0.0.1:5001
#   api|src/Api/Api.csproj|/opt/myapp-api|myapp-api|http://127.0.0.1:5200
#
# Kullanim / Usage:
#   SERVICES="..." bash pipeline.sh <komut>
#   komutlar / commands: backup | publish-source | deploy-artifacts |
#                        write-info | restart | health | rollback

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-Release}"

# Yorum ve bos satirlari ele / strip comments and blank lines
services_lines() {
  printf '%s\n' "${SERVICES:?SERVICES ortam degiskeni tanimli degil / SERVICES env not set}" \
    | grep -vE '^\s*(#.*)?$'
}

# Bir satirdan alan cek / extract a field from a line (1-based)
field() {
  printf '%s' "$1" | cut -d'|' -f"$2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

cmd_backup() {
  while IFS= read -r line; do
    local dd; dd="$(field "$line" 3)"
    if [ -d "$dd" ]; then
      rm -rf "${dd}.previous"
      cp -a "$dd" "${dd}.previous"
      echo "yedeklendi / backed up: $dd -> ${dd}.previous"
    else
      echo "yedeklenecek surum yok / nothing to back up: $dd"
    fi
  done < <(services_lines)
}

cmd_publish_source() {
  while IFS= read -r line; do
    local csproj dd staging
    csproj="$(field "$line" 2)"
    dd="$(field "$line" 3)"
    staging="$(mktemp -d)"
    dotnet publish "$csproj" --configuration "$CONFIG" --output "$staging" /p:UseSharedCompilation=false
    mkdir -p "$dd"
    rsync -a --delete "$staging/" "$dd/"
    rm -rf "$staging"
    echo "yayinlandi (kaynaktan) / published (from source): $csproj -> $dd"
  done < <(services_lines)
}

cmd_deploy_artifacts() {
  : "${ARTIFACT_ROOT:?ARTIFACT_ROOT tanimli degil / ARTIFACT_ROOT not set}"
  while IFS= read -r line; do
    local name dd src
    name="$(field "$line" 1)"
    dd="$(field "$line" 3)"
    src="${ARTIFACT_ROOT}/${name}"
    if [ ! -d "$src" ]; then
      echo "artifact bulunamadi / artifact not found: $src"
      exit 1
    fi
    mkdir -p "$dd"
    rsync -a --delete "$src/" "$dd/"
    echo "yayinlandi (artifact) / published (artifact): $src -> $dd"
  done < <(services_lines)
}

cmd_write_info() {
  while IFS= read -r line; do
    local dd; dd="$(field "$line" 3)"
    [ -d "$dd" ] || continue
    cat > "${dd}/.deploy-info" <<EOF
deploy_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=${GIT_SHA:-unknown}
deployed_by=${DEPLOYED_BY:-unknown}
note=${DEPLOY_NOTE:-}
EOF
    echo "deploy bilgisi yazildi / deploy info written: ${dd}/.deploy-info"
  done < <(services_lines)
}

cmd_restart() {
  while IFS= read -r line; do
    local dd svc
    dd="$(field "$line" 3)"
    svc="$(field "$line" 4)"
    pkill -f "dotnet ${dd}" || true
    sleep 1
    systemctl restart "$svc"
    echo "yeniden baslatildi / restarted: $svc"
  done < <(services_lines)
}

cmd_health() {
  local fail=0
  while IFS= read -r line; do
    local url
    url="$(field "$line" 5)"
    if ! bash "${SCRIPT_DIR}/verify-health.sh" "$url"; then
      fail=1
    fi
  done < <(services_lines)
  return "$fail"
}

cmd_rollback() {
  local fail=0
  while IFS= read -r line; do
    local dd svc
    dd="$(field "$line" 3)"
    svc="$(field "$line" 4)"
    if [ -d "${dd}.previous" ]; then
      pkill -f "dotnet ${dd}" || true
      sleep 1
      rm -rf "$dd"
      cp -a "${dd}.previous" "$dd"
      systemctl restart "$svc"
      echo "geri alindi / rolled back: ${dd}.previous -> $dd"
    else
      echo "geri alinacak surum yok / no previous release: ${dd}.previous"
      fail=1
    fi
  done < <(services_lines)
  return "$fail"
}

main() {
  local command="${1:-}"
  case "$command" in
    backup)           cmd_backup ;;
    publish-source)   cmd_publish_source ;;
    deploy-artifacts) cmd_deploy_artifacts ;;
    write-info)       cmd_write_info ;;
    restart)          cmd_restart ;;
    health)           cmd_health ;;
    rollback)         cmd_rollback ;;
    *)
      echo "kullanim / usage: SERVICES=... bash pipeline.sh <backup|publish-source|deploy-artifacts|write-info|restart|health|rollback>"
      exit 1
      ;;
  esac
}

main "$@"
