#!/usr/bin/env bash
#
# CI/CD Blueprint - deploy oncesi altyapi hazirligi (EF Core DB migration)
# CI/CD Blueprint - pre-deploy infra prep (EF Core DB migrations)
#
# Blue-green sirasi / order:
#   1) ensure-infra (bu script) — geriye uyumlu migration
#   2) idle renge yayin / publish to idle
#   3) restart + health (socket)
#   4) switch (nginx reload)
#
# GitHub Variables (duzenleme gerekmez / no script edits):
#   EF_PROJECT         — migration iceren .csproj (zorunlu / required when step runs)
#   EF_STARTUP_PROJECT — startup .csproj (opsiyonel; yoksa SERVICES ilk satirindaki csproj)
#
# Secret APP_ENV: ConnectionStrings__... satirlari migration sirasinda ortama yuklenir.
# APP_ENV secret: ConnectionStrings__... lines are exported before migration runs.
#
# Migration runner uzerinde calisir (onerilen); uzak sunucuda SDK gerekmez.
# Migration runs on the CI runner (recommended); no SDK required on the remote host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_TARGET="${DEPLOY_TARGET:-local}"
CONFIG="${CONFIG:-Release}"

validate_csproj_path() {
  local val="$1" label="$2"
  if [ -z "$val" ]; then
    echo "HATA / ERROR: $label bos olamaz / must not be empty"
    exit 1
  fi
  if ! printf '%s' "$val" | grep -qE '^[a-zA-Z0-9/_.@-]+\.csproj$'; then
    echo "HATA / ERROR: $label gecersiz / invalid: '$val'"
    echo "  Ornek / example: src/Infrastructure/Infrastructure.csproj"
    exit 1
  fi
}

load_app_env() {
  if [ -z "${APP_ENV:-}" ]; then
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
      *=*)
        local key="${line%%=*}"
        local val="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [ -z "$key" ] && continue
        export "${key}=${val}"
        ;;
    esac
  done <<< "$APP_ENV"
}

ef_startup_from_services() {
  if [ -n "${EF_STARTUP_PROJECT:-}" ]; then
    printf '%s' "$EF_STARTUP_PROJECT"
    return
  fi
  if [ -z "${SERVICES:-}" ]; then
    printf ''
    return
  fi
  printf '%s\n' "$SERVICES" \
    | grep -vE '^\s*(#.*)?$' \
    | head -1 \
    | cut -d'|' -f2 \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

ensure_dotnet_ef() {
  if dotnet ef --version >/dev/null 2>&1; then
    return 0
  fi
  echo "dotnet-ef aracini kuruyor / installing dotnet-ef tool..."
  dotnet tool install --global dotnet-ef
  export PATH="${PATH}:${HOME}/.dotnet/tools"
  if ! dotnet ef --version >/dev/null 2>&1; then
    echo "HATA / ERROR: dotnet-ef kurulamadi / could not install dotnet-ef"
    exit 1
  fi
}

run_ef_migration() {
  local ef_project="${EF_PROJECT:-}"
  local startup

  if [ -z "$ef_project" ]; then
    if [ "${RUN_ENSURE_INFRA:-}" = "true" ]; then
      echo "HATA / ERROR: RUN_ENSURE_INFRA=true ama EF_PROJECT tanimli degil."
      echo "  GitHub Variables -> EF_PROJECT = migration iceren .csproj yolu"
      echo "  RUN_ENSURE_INFRA=true but EF_PROJECT is not set."
      exit 1
    fi
    echo "EF_PROJECT tanimli degil, migration atlaniyor / EF_PROJECT not set, skipping migration"
    return 0
  fi

  validate_csproj_path "$ef_project" "EF_PROJECT"
  if [ ! -f "$ef_project" ]; then
    echo "HATA / ERROR: EF_PROJECT bulunamadi / not found: $ef_project"
    exit 1
  fi

  startup="$(ef_startup_from_services)"
  if [ -z "$startup" ]; then
    echo "HATA / ERROR: EF_STARTUP_PROJECT veya SERVICES gerekli / EF_STARTUP_PROJECT or SERVICES required"
    exit 1
  fi
  validate_csproj_path "$startup" "EF_STARTUP_PROJECT"
  if [ ! -f "$startup" ]; then
    echo "HATA / ERROR: startup project bulunamadi / not found: $startup"
    exit 1
  fi

  if ! command -v dotnet >/dev/null 2>&1; then
    echo "HATA / ERROR: .NET SDK bulunamadi / .NET SDK not found on runner"
    exit 1
  fi

  ensure_dotnet_ef
  load_app_env

  echo "EF migration basliyor / starting EF migration"
  echo "  project=$ef_project"
  echo "  startup=$startup"
  echo "  configuration=$CONFIG"

  dotnet restore "$ef_project" --verbosity minimal /p:UseSharedCompilation=false
  dotnet restore "$startup" --verbosity minimal /p:UseSharedCompilation=false

  dotnet ef database update \
    --project "$ef_project" \
    --startup-project "$startup" \
    --configuration "$CONFIG"

  echo "EF migration tamamlandi / EF migration completed"
}

ensure_infra_local() {
  run_ef_migration
}

ensure_infra_remote() {
  # Runner'dan DB'ye baglan (onerilen). Sunucuda dotnet SDK gerekmez.
  # Connect to DB from runner (recommended). No dotnet SDK on server.
  run_ef_migration
}

case "$DEPLOY_TARGET" in
  remote)
    # shellcheck source=ssh-remote.sh
    source "${SCRIPT_DIR}/ssh-remote.sh"
    ssh_remote_init
    ensure_infra_remote
    ;;
  local|*)
    ensure_infra_local
    ;;
esac
