#!/usr/bin/env bash
#
# CI/CD Blueprint - tek seferlik host kurulumu / one-time host setup
#
# SERVICES icindeki her servis icin bir systemd birimi olusturur.
# Creates a systemd unit for each service defined in SERVICES.
#
# Turetilen degerler / derived values:
#   - dll        = <csproj adi>.dll (varsayilan .NET ciktisi / default .NET output)
#   - port       = health_url icindeki port / port from health_url
#   - calisma    = deploy_dir
#
# Kullanim / Usage (root):
#   sudo SERVICES="..." bash setup-host.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "root ile calistir / run as root: sudo SERVICES=... bash setup-host.sh"
  exit 1
fi

DOTNET_PATH="${DOTNET_PATH:-/usr/bin/dotnet}"
ASPNETCORE_ENV="${ASPNETCORE_ENV:-Production}"

if [ ! -x "$DOTNET_PATH" ] && ! command -v "$DOTNET_PATH" >/dev/null 2>&1; then
  echo "dotnet bulunamadi / dotnet not found: $DOTNET_PATH (DOTNET_PATH ile ver / set DOTNET_PATH)"
  exit 1
fi

printf '%s\n' "${SERVICES:?SERVICES ortam degiskeni tanimli degil / SERVICES env not set}" \
  | grep -vE '^\s*(#.*)?$' \
  | while IFS= read -r line; do
      csproj="$(printf '%s' "$line" | cut -d'|' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      dd="$(printf '%s' "$line" | cut -d'|' -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      svc="$(printf '%s' "$line" | cut -d'|' -f4 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      hurl="$(printf '%s' "$line" | cut -d'|' -f5 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

      port="$(printf '%s' "$hurl" | sed -E 's#.*:([0-9]+).*#\1#')"
      dll="$(basename "$csproj" .csproj).dll"

      cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=${svc} .NET service (CI/CD Blueprint)
After=network.target

[Service]
WorkingDirectory=${dd}
ExecStart=${DOTNET_PATH} ${dd}/${dll} --urls http://0.0.0.0:${port}
Restart=always
RestartSec=5
Environment=ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENV}
Environment=DOTNET_USE_POLLING_FILE_WATCHER=1

[Install]
WantedBy=multi-user.target
EOF

      systemctl daemon-reload
      systemctl enable "$svc"
      echo "systemd birimi olusturuldu / unit created: ${svc} (port ${port}, ${dll})"
    done

echo "tamam / done. Ilk deploy sonrasi baslat / start after first deploy: systemctl start <servis>"
